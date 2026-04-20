//! C FFI for codex-core, designed for Swift interop.
//!
//! All data crosses the boundary as JSON strings (C `char *`).
//! Swift calls `codex_create` to start a session, `codex_send` to send a prompt
//! (receiving events via callback), and `codex_destroy` to clean up.

use std::collections::HashMap;
use std::ffi::CStr;
use std::ffi::CString;
use std::io::Write;
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicI64;
use std::sync::atomic::Ordering;
use std::time::Duration;

use codex_common::model_presets::builtin_model_presets;
use codex_core::AuthManager;
use codex_core::CodexConversation;
use codex_core::ConversationManager;
use codex_core::NewConversation;
use codex_core::config::Config;
use codex_core::config::ConfigOverrides;
use codex_core::config::OPENAI_DEFAULT_MODEL;
use codex_core::config::persist_model_selection;
use codex_core::config_types::McpServerTransportConfig;
use codex_core::protocol::AskForApproval;
use codex_core::protocol::EventMsg;
use codex_core::protocol::McpAuthStatus;
use codex_core::protocol::Op;
use codex_core::protocol::SandboxPolicy;
use codex_exec::event_processor_with_jsonl_output::EventProcessorWithJsonOutput;
use codex_protocol::config_types::ReasoningEffort;
use codex_protocol::config_types::SandboxMode;
use codex_protocol::protocol::SessionSource;
use codex_protocol::user_input::UserInput;
use mcp_types::Resource as McpResource;
use mcp_types::ResourceTemplate as McpResourceTemplate;
use serde::Serialize;
use tokio::runtime::Runtime;

/// Log to stderr for debugging.
fn log(msg: &str) {
    let _ = writeln!(std::io::stderr(), "[codex-ffi] {msg}");
}

const CREATE_CANCELLED_ERROR: &str = "create_cancelled";
const CREATE_CANCELLATION_POLL_INTERVAL: Duration = Duration::from_millis(25);

static NEXT_CREATE_CANCELLATION_TOKEN_ID: AtomicI64 = AtomicI64::new(1);
static CREATE_CANCELLATION_TOKENS: OnceLock<Mutex<HashMap<i64, Arc<AtomicBool>>>> = OnceLock::new();

fn create_cancellation_tokens() -> &'static Mutex<HashMap<i64, Arc<AtomicBool>>> {
    CREATE_CANCELLATION_TOKENS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn create_cancellation_token_for(token_id: i64) -> Option<Arc<AtomicBool>> {
    if token_id <= 0 {
        return None;
    }

    let tokens = create_cancellation_tokens()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);

    match tokens.get(&token_id) {
        Some(token) => Some(token.clone()),
        None => {
            log(&format!(
                "create cancellation token missing id={token_id}; treating as cancelled"
            ));
            Some(Arc::new(AtomicBool::new(true)))
        }
    }
}

fn is_create_cancelled(token: &Option<Arc<AtomicBool>>) -> bool {
    token
        .as_ref()
        .is_some_and(|flag| flag.load(Ordering::SeqCst))
}

async fn wait_for_create_cancelled(token: Arc<AtomicBool>) {
    while !token.load(Ordering::SeqCst) {
        tokio::time::sleep(CREATE_CANCELLATION_POLL_INTERVAL).await;
    }
}

/// Opaque handle to a running codex session.
pub struct CodexHandle {
    runtime: Runtime,
    conversation: Arc<CodexConversation>,
    config: Config,
    event_processor: std::sync::Mutex<EventProcessorWithJsonOutput>,
    cancelled: AtomicBool,
}

/// Type for the event callback. Called with a JSON string for each event.
/// The `user_data` pointer is passed through from `codex_send`.
pub type EventCallback = extern "C" fn(event_json: *const c_char, user_data: *mut std::ffi::c_void);

#[derive(Serialize)]
struct ModelSelectionResponse {
    ok: bool,
    model: Option<String>,
    reasoning_effort: Option<String>,
    active_profile: Option<String>,
    error: Option<String>,
}

#[derive(Serialize)]
struct ApprovalSandboxResponse {
    ok: bool,
    approval_policy: Option<String>,
    sandbox_mode: Option<String>,
    error: Option<String>,
}

#[derive(Serialize)]
struct ModelPresetsResponse {
    ok: bool,
    presets: Vec<ModelPresetResponse>,
    error: Option<String>,
}

#[derive(Serialize)]
struct ModelPresetResponse {
    id: String,
    model: String,
    display_name: String,
    description: String,
    default_reasoning_effort: String,
    supported_reasoning_efforts: Vec<ReasoningEffortPresetResponse>,
    is_default: bool,
}

#[derive(Serialize)]
struct ReasoningEffortPresetResponse {
    effort: String,
    description: String,
}

#[derive(Serialize)]
struct McpStatusResponse {
    ok: bool,
    servers: Vec<McpServerStatusResponse>,
    errors: Vec<String>,
    error: Option<String>,
}

#[derive(Serialize)]
struct McpServerStatusResponse {
    name: String,
    enabled: bool,
    status: String,
    auth_status: String,
    auth_label: String,
    startup_timeout_sec: Option<f64>,
    tool_timeout_sec: Option<f64>,
    transport: McpServerTransportResponse,
    tools: Vec<String>,
    resources: Vec<McpResourceSummary>,
    resource_templates: Vec<McpResourceTemplateSummary>,
    errors: Vec<String>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum McpServerTransportResponse {
    Stdio {
        command: String,
        args: Vec<String>,
        cwd: Option<String>,
        env_keys: Vec<String>,
        env_vars: Vec<String>,
    },
    StreamableHttp {
        url: String,
        bearer_token_env_var: Option<String>,
        http_header_keys: Vec<String>,
        env_http_headers: Vec<McpEnvHttpHeaderBinding>,
    },
}

#[derive(Serialize)]
struct McpEnvHttpHeaderBinding {
    name: String,
    env_var: String,
}

#[derive(Serialize)]
struct McpResourceSummary {
    name: String,
    title: Option<String>,
    uri: String,
}

#[derive(Serialize)]
struct McpResourceTemplateSummary {
    name: String,
    title: Option<String>,
    uri_template: String,
}

fn c_optional_string(ptr: *const c_char) -> Result<Option<String>, String> {
    if ptr.is_null() {
        return Ok(None);
    }
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| "invalid UTF-8 in C string".to_string())?
        .trim()
        .to_string();
    if value.is_empty() {
        Ok(None)
    } else {
        Ok(Some(value))
    }
}

fn c_required_string(ptr: *const c_char, field: &str) -> Result<String, String> {
    match c_optional_string(ptr)? {
        Some(value) => Ok(value),
        None => Err(format!("{field} is required")),
    }
}

fn parse_reasoning_effort(value: Option<&str>) -> Result<Option<ReasoningEffort>, String> {
    match value {
        None => Ok(None),
        Some("minimal") => Ok(Some(ReasoningEffort::Minimal)),
        Some("low") => Ok(Some(ReasoningEffort::Low)),
        Some("medium") => Ok(Some(ReasoningEffort::Medium)),
        Some("high") => Ok(Some(ReasoningEffort::High)),
        Some(other) => Err(format!("unsupported reasoning effort `{other}`")),
    }
}

fn parse_approval_policy(value: Option<&str>) -> Result<Option<AskForApproval>, String> {
    match value {
        None => Ok(None),
        Some("untrusted") => Ok(Some(AskForApproval::UnlessTrusted)),
        Some("on-failure") => Ok(Some(AskForApproval::OnFailure)),
        Some("on-request") => Ok(Some(AskForApproval::OnRequest)),
        Some("never") => Ok(Some(AskForApproval::Never)),
        Some(other) => Err(format!("unsupported approval policy `{other}`")),
    }
}

fn parse_sandbox_mode(value: Option<&str>) -> Result<Option<SandboxMode>, String> {
    match value {
        None => Ok(None),
        Some("read-only") => Ok(Some(SandboxMode::ReadOnly)),
        Some("workspace-write") => Ok(Some(SandboxMode::WorkspaceWrite)),
        Some("danger-full-access") => Ok(Some(SandboxMode::DangerFullAccess)),
        Some(other) => Err(format!("unsupported sandbox mode `{other}`")),
    }
}

fn sandbox_mode_for_policy(policy: &SandboxPolicy) -> &'static str {
    match policy {
        SandboxPolicy::ReadOnly => "read-only",
        SandboxPolicy::WorkspaceWrite { .. } => "workspace-write",
        SandboxPolicy::DangerFullAccess => "danger-full-access",
    }
}

fn selection_response_json(response: ModelSelectionResponse) -> *mut c_char {
    let json = match serde_json::to_string(&response) {
        Ok(json) => json,
        Err(err) => {
            log(&format!("Failed to encode selection response JSON: {err}"));
            "{\"ok\":false,\"error\":\"internal serialization error\"}".to_string()
        }
    };

    match CString::new(json) {
        Ok(c_string) => c_string.into_raw(),
        Err(err) => {
            log(&format!(
                "Failed to build CString for selection response: {err}"
            ));
            std::ptr::null_mut()
        }
    }
}

fn approval_sandbox_response_json(response: ApprovalSandboxResponse) -> *mut c_char {
    let json = match serde_json::to_string(&response) {
        Ok(json) => json,
        Err(err) => {
            log(&format!(
                "Failed to encode approval/sandbox response JSON: {err}"
            ));
            "{\"ok\":false,\"error\":\"internal serialization error\"}".to_string()
        }
    };

    match CString::new(json) {
        Ok(c_string) => c_string.into_raw(),
        Err(err) => {
            log(&format!(
                "Failed to build CString for approval/sandbox response: {err}"
            ));
            std::ptr::null_mut()
        }
    }
}

fn model_presets_response_json(response: ModelPresetsResponse) -> *mut c_char {
    let json = match serde_json::to_string(&response) {
        Ok(json) => json,
        Err(err) => {
            log(&format!(
                "Failed to encode model presets response JSON: {err}"
            ));
            "{\"ok\":false,\"presets\":[],\"error\":\"internal serialization error\"}".to_string()
        }
    };

    match CString::new(json) {
        Ok(c_string) => c_string.into_raw(),
        Err(err) => {
            log(&format!(
                "Failed to build CString for model presets response: {err}"
            ));
            std::ptr::null_mut()
        }
    }
}

fn mcp_status_response_json(response: McpStatusResponse) -> *mut c_char {
    let json = match serde_json::to_string(&response) {
        Ok(json) => json,
        Err(err) => {
            log(&format!("Failed to encode MCP status response JSON: {err}"));
            "{\"ok\":false,\"servers\":[],\"errors\":[],\"error\":\"internal serialization error\"}"
                .to_string()
        }
    };

    match CString::new(json) {
        Ok(c_string) => c_string.into_raw(),
        Err(err) => {
            log(&format!(
                "Failed to build CString for MCP status response: {err}"
            ));
            std::ptr::null_mut()
        }
    }
}

fn duration_to_seconds(duration: Option<Duration>) -> Option<f64> {
    duration.map(|value| value.as_secs_f64())
}

fn format_transport(config: &McpServerTransportConfig) -> McpServerTransportResponse {
    match config {
        McpServerTransportConfig::Stdio {
            command,
            args,
            env,
            env_vars,
            cwd,
        } => {
            let mut env_keys = env
                .as_ref()
                .map(|map| map.keys().cloned().collect::<Vec<_>>())
                .unwrap_or_default();
            env_keys.sort();

            let mut env_vars = env_vars.clone();
            env_vars.sort();

            McpServerTransportResponse::Stdio {
                command: command.clone(),
                args: args.clone(),
                cwd: cwd.as_ref().map(|path| path.display().to_string()),
                env_keys,
                env_vars,
            }
        }
        McpServerTransportConfig::StreamableHttp {
            url,
            bearer_token_env_var,
            http_headers,
            env_http_headers,
        } => {
            let mut http_header_keys = http_headers
                .as_ref()
                .map(|headers| headers.keys().cloned().collect::<Vec<_>>())
                .unwrap_or_default();
            http_header_keys.sort();

            let mut env_http_header_pairs = env_http_headers
                .as_ref()
                .map(|headers| {
                    headers
                        .iter()
                        .map(|(name, env_var)| McpEnvHttpHeaderBinding {
                            name: name.clone(),
                            env_var: env_var.clone(),
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            env_http_header_pairs.sort_by(|a, b| a.name.cmp(&b.name));

            McpServerTransportResponse::StreamableHttp {
                url: url.clone(),
                bearer_token_env_var: bearer_token_env_var.clone(),
                http_header_keys,
                env_http_headers: env_http_header_pairs,
            }
        }
    }
}

fn summarize_resource(resource: McpResource) -> McpResourceSummary {
    McpResourceSummary {
        name: resource.name,
        title: resource.title,
        uri: resource.uri,
    }
}

fn summarize_resource_template(template: McpResourceTemplate) -> McpResourceTemplateSummary {
    McpResourceTemplateSummary {
        name: template.name,
        title: template.title,
        uri_template: template.uri_template,
    }
}

async fn load_mcp_status(cwd: &str) -> Result<McpStatusResponse, String> {
    let config = load_config_with_optional_overrides(cwd, None, None, None, None).await?;
    let auth_manager = AuthManager::shared(config.codex_home.clone(), true);
    let conversation_manager = ConversationManager::new(auth_manager, SessionSource::Exec);
    let NewConversation {
        conversation_id: _,
        conversation,
        session_configured: _,
    } = conversation_manager
        .new_conversation(config.clone())
        .await
        .map_err(|err| format!("conversation: {err}"))?;

    conversation
        .submit(Op::ListMcpTools)
        .await
        .map_err(|err| format!("mcp list submit: {err}"))?;

    let mut startup_errors: Vec<String> = Vec::new();
    let mut mcp_response = None;
    let mut events_seen = 0usize;

    while events_seen < 10_000 {
        let event = conversation
            .next_event()
            .await
            .map_err(|err| format!("mcp list event: {err}"))?;
        events_seen += 1;

        match event.msg {
            EventMsg::McpListToolsResponse(response) => {
                mcp_response = Some(response);
                break;
            }
            EventMsg::Error(error_event) => {
                let message = error_event.message.trim().to_string();
                if !message.is_empty() {
                    startup_errors.push(message);
                }
            }
            _ => {}
        }
    }

    // Best effort shutdown; errors are non-fatal for the status payload.
    let _ = conversation.submit(Op::Shutdown).await;

    let mcp_response = mcp_response.ok_or_else(|| "timed out waiting for MCP tools".to_string())?;
    let mut server_names: Vec<String> = config.mcp_servers.keys().cloned().collect();
    server_names.sort();

    let mut server_errors: std::collections::HashMap<String, Vec<String>> =
        std::collections::HashMap::new();
    let mut global_errors = Vec::new();

    for message in startup_errors {
        let lower = message.to_lowercase();
        let mut matched = false;
        for server in &server_names {
            let needle = format!("`{server}`");
            if message.contains(&needle) || lower.contains(&server.to_lowercase()) {
                server_errors
                    .entry(server.clone())
                    .or_default()
                    .push(message.clone());
                matched = true;
            }
        }
        if !matched {
            global_errors.push(message);
        }
    }

    let mut servers = Vec::new();
    for name in server_names {
        let Some(cfg) = config.mcp_servers.get(&name) else {
            continue;
        };

        let prefix = format!("mcp__{name}__");
        let mut tools: Vec<String> = mcp_response
            .tools
            .keys()
            .filter_map(|qualified_name| {
                qualified_name
                    .strip_prefix(&prefix)
                    .map(std::string::ToString::to_string)
            })
            .collect();
        tools.sort();
        tools.dedup();

        let mut resources = mcp_response
            .resources
            .get(&name)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .map(summarize_resource)
            .collect::<Vec<_>>();
        resources.sort_by(|a, b| a.name.cmp(&b.name));

        let mut resource_templates = mcp_response
            .resource_templates
            .get(&name)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .map(summarize_resource_template)
            .collect::<Vec<_>>();
        resource_templates.sort_by(|a, b| a.name.cmp(&b.name));

        let auth_status = mcp_response
            .auth_statuses
            .get(&name)
            .copied()
            .unwrap_or(McpAuthStatus::Unsupported);
        let errors = server_errors.remove(&name).unwrap_or_default();
        let status = if !cfg.enabled {
            "disabled".to_string()
        } else if !errors.is_empty() {
            "error".to_string()
        } else {
            "enabled".to_string()
        };

        servers.push(McpServerStatusResponse {
            name,
            enabled: cfg.enabled,
            status,
            auth_status: serde_json::to_string(&auth_status)
                .unwrap_or_else(|_| "\"unsupported\"".to_string())
                .trim_matches('"')
                .to_string(),
            auth_label: auth_status.to_string(),
            startup_timeout_sec: duration_to_seconds(cfg.startup_timeout_sec),
            tool_timeout_sec: duration_to_seconds(cfg.tool_timeout_sec),
            transport: format_transport(&cfg.transport),
            tools,
            resources,
            resource_templates,
            errors,
        });
    }

    for leftovers in server_errors.into_values() {
        global_errors.extend(leftovers);
    }

    Ok(McpStatusResponse {
        ok: true,
        servers,
        errors: global_errors,
        error: None,
    })
}

fn build_config_overrides(
    cwd: &str,
    model: Option<String>,
    approval_policy: Option<AskForApproval>,
    sandbox_mode: Option<SandboxMode>,
) -> ConfigOverrides {
    ConfigOverrides {
        model,
        review_model: None,
        cwd: Some(PathBuf::from(cwd)),
        approval_policy,
        sandbox_mode,
        model_provider: None,
        config_profile: None,
        codex_linux_sandbox_exe: None,
        base_instructions: None,
        include_apply_patch_tool: None,
        include_view_image_tool: None,
        show_raw_agent_reasoning: None,
        tools_web_search_request: None,
        experimental_sandbox_command_assessment: None,
        additional_writable_roots: Vec::new(),
    }
}

async fn load_config_with_optional_overrides(
    cwd: &str,
    model_override: Option<String>,
    effort_override: Option<ReasoningEffort>,
    approval_override: Option<AskForApproval>,
    sandbox_override: Option<SandboxMode>,
) -> Result<Config, String> {
    let overrides =
        build_config_overrides(cwd, model_override, approval_override, sandbox_override);

    let mut cli_overrides = Vec::new();
    if let Some(effort) = effort_override {
        cli_overrides.push((
            "model_reasoning_effort".to_string(),
            toml::Value::String(effort.to_string()),
        ));
    }

    match Config::load_with_cli_overrides(cli_overrides, overrides.clone()).await {
        Ok(config) => Ok(config),
        Err(primary_err) if effort_override.is_none() => {
            // Some local config files include unsupported effort values.
            // Retry with a safe fallback so the GUI still boots.
            let fallback_overrides = vec![(
                "model_reasoning_effort".to_string(),
                toml::Value::String(ReasoningEffort::Medium.to_string()),
            )];
            match Config::load_with_cli_overrides(fallback_overrides, overrides).await {
                Ok(config) => {
                    log(&format!(
                        "Config load recovered with fallback reasoning effort: {primary_err}"
                    ));
                    Ok(config)
                }
                Err(fallback_err) => Err(format!(
                    "config: {primary_err}; fallback failed: {fallback_err}"
                )),
            }
        }
        Err(err) => Err(format!("config: {err}")),
    }
}

/// Create a new codex session. Returns an opaque handle.
///
/// `cwd` - working directory (C string, UTF-8)
///
/// Returns null on failure.
#[unsafe(no_mangle)]
pub extern "C" fn codex_create(cwd: *const c_char) -> *mut CodexHandle {
    codex_create_with_options(
        cwd,
        std::ptr::null(),
        std::ptr::null(),
        std::ptr::null(),
        std::ptr::null(),
    )
}

/// Allocate a cancellation token that can abort in-flight `codex_create*` calls.
#[unsafe(no_mangle)]
pub extern "C" fn codex_create_cancellation_token_new() -> i64 {
    let token_id = NEXT_CREATE_CANCELLATION_TOKEN_ID.fetch_add(1, Ordering::SeqCst);
    if token_id <= 0 {
        log("create cancellation token id overflow");
        return 0;
    }

    let mut tokens = create_cancellation_tokens()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    tokens.insert(token_id, Arc::new(AtomicBool::new(false)));
    token_id
}

/// Cancel an in-flight create associated with `token_id`.
#[unsafe(no_mangle)]
pub extern "C" fn codex_create_cancellation_token_cancel(token_id: i64) {
    if token_id <= 0 {
        return;
    }

    let token = {
        let tokens = create_cancellation_tokens()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        tokens.get(&token_id).cloned()
    };

    if let Some(token) = token {
        token.store(true, Ordering::SeqCst);
    }
}

/// Free a create cancellation token.
#[unsafe(no_mangle)]
pub extern "C" fn codex_create_cancellation_token_free(token_id: i64) {
    if token_id <= 0 {
        return;
    }

    let token = {
        let mut tokens = create_cancellation_tokens()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        tokens.remove(&token_id)
    };

    if let Some(token) = token {
        token.store(true, Ordering::SeqCst);
    }
}

/// Create a new codex session with optional model, reasoning, and policy overrides.
#[unsafe(no_mangle)]
pub extern "C" fn codex_create_with_options(
    cwd: *const c_char,
    model: *const c_char,
    reasoning_effort: *const c_char,
    approval_policy: *const c_char,
    sandbox_mode: *const c_char,
) -> *mut CodexHandle {
    codex_create_with_options_and_cancellation(
        cwd,
        model,
        reasoning_effort,
        approval_policy,
        sandbox_mode,
        0,
    )
}

/// Create a new codex session with optional overrides and a create cancellation token.
#[unsafe(no_mangle)]
pub extern "C" fn codex_create_with_options_and_cancellation(
    cwd: *const c_char,
    model: *const c_char,
    reasoning_effort: *const c_char,
    approval_policy: *const c_char,
    sandbox_mode: *const c_char,
    create_cancellation_token_id: i64,
) -> *mut CodexHandle {
    let cwd_str = c_optional_string(cwd)
        .ok()
        .flatten()
        .unwrap_or_else(|| ".".to_string());
    let model_override = match c_optional_string(model) {
        Ok(value) => value,
        Err(err) => {
            log(&format!("Invalid model override: {err}"));
            return std::ptr::null_mut();
        }
    };
    let effort_override = match c_optional_string(reasoning_effort)
        .and_then(|raw| parse_reasoning_effort(raw.as_deref()))
    {
        Ok(value) => value,
        Err(err) => {
            log(&format!("Invalid reasoning override: {err}"));
            return std::ptr::null_mut();
        }
    };
    let approval_override = match c_optional_string(approval_policy)
        .and_then(|raw| parse_approval_policy(raw.as_deref()))
    {
        Ok(value) => value,
        Err(err) => {
            log(&format!("Invalid approval policy override: {err}"));
            return std::ptr::null_mut();
        }
    };
    let sandbox_override =
        match c_optional_string(sandbox_mode).and_then(|raw| parse_sandbox_mode(raw.as_deref())) {
            Ok(value) => value,
            Err(err) => {
                log(&format!("Invalid sandbox mode override: {err}"));
                return std::ptr::null_mut();
            }
        };

    let create_cancellation = create_cancellation_token_for(create_cancellation_token_id);

    log(&format!(
        "codex_create_with_options called cwd={cwd_str}, model={model_override:?}, effort={effort_override:?}, approval={approval_override:?}, sandbox={sandbox_override:?}, create_token={create_cancellation_token_id}"
    ));

    if is_create_cancelled(&create_cancellation) {
        log("codex_create cancelled before initialization");
        return std::ptr::null_mut();
    }

    // Spawn on a dedicated thread so we own the tokio runtime cleanly.
    let result = std::thread::spawn(move || -> Option<CodexHandle> {
        if is_create_cancelled(&create_cancellation) {
            log("codex_create cancelled before runtime initialization");
            return None;
        }

        let rt = match Runtime::new() {
            Ok(rt) => rt,
            Err(e) => {
                log(&format!("Failed to create tokio runtime: {e}"));
                return None;
            }
        };

        let conversation_result = rt.block_on(async {
            log("Loading config...");
            let config = if let Some(create_cancellation) = create_cancellation.clone() {
                tokio::select! {
                    _ = wait_for_create_cancelled(create_cancellation) => {
                        return Err(CREATE_CANCELLED_ERROR.to_string());
                    }
                    loaded = load_config_with_optional_overrides(
                        &cwd_str,
                        model_override.clone(),
                        effort_override,
                        approval_override,
                        sandbox_override,
                    ) => match loaded {
                        Ok(c) => {
                            log(&format!(
                                "Config loaded. model={}, cwd={}",
                                c.model,
                                c.cwd.display()
                            ));
                            c
                        }
                        Err(e) => {
                            log(&format!("Config load failed: {e}"));
                            return Err(e);
                        }
                    }
                }
            } else {
                match load_config_with_optional_overrides(
                    &cwd_str,
                    model_override.clone(),
                    effort_override,
                    approval_override,
                    sandbox_override,
                )
                .await
                {
                    Ok(c) => {
                        log(&format!(
                            "Config loaded. model={}, cwd={}",
                            c.model,
                            c.cwd.display()
                        ));
                        c
                    }
                    Err(e) => {
                        log(&format!("Config load failed: {e}"));
                        return Err(e);
                    }
                }
            };

            if is_create_cancelled(&create_cancellation) {
                return Err(CREATE_CANCELLED_ERROR.to_string());
            }

            log("Creating auth manager...");
            let auth_manager = AuthManager::shared(config.codex_home.clone(), true);

            log("Creating conversation manager...");
            let conversation_manager = ConversationManager::new(auth_manager, SessionSource::Exec);

            log("Creating new conversation...");
            let nc = if let Some(create_cancellation) = create_cancellation.clone() {
                tokio::select! {
                    _ = wait_for_create_cancelled(create_cancellation) => {
                        return Err(CREATE_CANCELLED_ERROR.to_string());
                    }
                    created = conversation_manager.new_conversation(config.clone()) => match created {
                        Ok(nc) => {
                            log("Conversation created successfully");
                            nc
                        }
                        Err(e) => {
                            log(&format!("new_conversation failed: {e}"));
                            return Err(format!("conversation: {e}"));
                        }
                    }
                }
            } else {
                match conversation_manager.new_conversation(config.clone()).await {
                    Ok(nc) => {
                        log("Conversation created successfully");
                        nc
                    }
                    Err(e) => {
                        log(&format!("new_conversation failed: {e}"));
                        return Err(format!("conversation: {e}"));
                    }
                }
            };

            if is_create_cancelled(&create_cancellation) {
                let _ = nc.conversation.submit(Op::Shutdown).await;
                return Err(CREATE_CANCELLED_ERROR.to_string());
            }

            Ok((config, nc))
        });

        match conversation_result {
            Ok((
                config,
                NewConversation {
                    conversation_id: _,
                    conversation,
                    session_configured: _,
                },
            )) => {
                if is_create_cancelled(&create_cancellation) {
                    log("codex_create cancelled after conversation initialization");
                    rt.block_on(async {
                        let _ = conversation.submit(Op::Shutdown).await;
                    });
                    return None;
                }
                log("CodexHandle created successfully");
                Some(CodexHandle {
                    runtime: rt,
                    conversation,
                    config,
                    event_processor: std::sync::Mutex::new(EventProcessorWithJsonOutput::new(None)),
                    cancelled: AtomicBool::new(false),
                })
            }
            Err(msg) if msg == CREATE_CANCELLED_ERROR => {
                log("codex_create cancelled");
                None
            }
            Err(msg) => {
                log(&format!("codex_create failed: {msg}"));
                None
            }
        }
    })
    .join()
    .unwrap_or_else(|e| {
        log(&format!("Thread panicked: {e:?}"));
        None
    });

    match result {
        Some(handle) => Box::into_raw(Box::new(handle)),
        None => {
            log("Returning null handle");
            std::ptr::null_mut()
        }
    }
}

/// Send a prompt and receive events via callback.
///
/// This is blocking - it runs the full turn and calls `callback` for each
/// JSONL event. Call from a background thread in Swift.
///
/// Returns 0 on success, -1 on failure.
#[unsafe(no_mangle)]
pub extern "C" fn codex_send(
    handle: *mut CodexHandle,
    prompt: *const c_char,
    callback: EventCallback,
    user_data: *mut std::ffi::c_void,
) -> i32 {
    if handle.is_null() || prompt.is_null() {
        return -1;
    }

    let handle = unsafe { &*handle };
    let prompt_str = match unsafe { CStr::from_ptr(prompt) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -1,
    };

    let conversation = handle.conversation.clone();
    let cwd = handle.config.cwd.to_path_buf();
    let model = handle.config.model.clone();
    let effort = handle.config.model_reasoning_effort;
    let summary = handle.config.model_reasoning_summary;
    let approval_policy = handle.config.approval_policy;
    let sandbox_policy = handle.config.sandbox_policy.clone();

    if handle.cancelled.swap(false, Ordering::SeqCst) {
        return -1;
    }

    handle.runtime.block_on(async {
        // Submit the user turn
        let _task_id = match conversation
            .submit(Op::UserTurn {
                items: vec![UserInput::Text { text: prompt_str }],
                cwd,
                approval_policy,
                sandbox_policy,
                model,
                effort,
                summary,
                final_output_json_schema: None,
            })
            .await
        {
            Ok(id) => id,
            Err(_) => return -1,
        };

        if handle.cancelled.swap(false, Ordering::SeqCst) {
            let _ = conversation.submit(Op::Interrupt).await;
        }

        // Drain events until TaskComplete
        loop {
            match conversation.next_event().await {
                Ok(event) => {
                    let is_complete = matches!(event.msg, EventMsg::TaskComplete(_));

                    // Convert internal events to JSONL ThreadEvents
                    let thread_events = {
                        let mut proc = handle
                            .event_processor
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        proc.collect_thread_events(&event)
                    };

                    for thread_event in thread_events {
                        if let Ok(json) = serde_json::to_string(&thread_event)
                            && let Ok(cstr) = CString::new(json)
                        {
                            callback(cstr.as_ptr(), user_data);
                        }
                    }

                    if is_complete {
                        break;
                    }
                }
                Err(_) => return -1,
            }
        }

        handle.cancelled.store(false, Ordering::SeqCst);
        0
    })
}

/// Read the effective model selection from Codex config for the given cwd.
#[unsafe(no_mangle)]
pub extern "C" fn codex_get_model_selection_json(cwd: *const c_char) -> *mut c_char {
    let cwd_str = c_optional_string(cwd)
        .ok()
        .flatten()
        .unwrap_or_else(|| ".".to_string());

    let response = std::thread::spawn(move || -> ModelSelectionResponse {
        let rt = match Runtime::new() {
            Ok(rt) => rt,
            Err(err) => {
                return ModelSelectionResponse {
                    ok: false,
                    model: Some(OPENAI_DEFAULT_MODEL.to_string()),
                    reasoning_effort: Some(ReasoningEffort::Medium.to_string()),
                    active_profile: None,
                    error: Some(format!("runtime: {err}")),
                };
            }
        };

        match rt.block_on(load_config_with_optional_overrides(
            &cwd_str, None, None, None, None,
        )) {
            Ok(config) => ModelSelectionResponse {
                ok: true,
                model: Some(config.model),
                reasoning_effort: config
                    .model_reasoning_effort
                    .map(|effort| effort.to_string()),
                active_profile: config.active_profile,
                error: None,
            },
            Err(err) => ModelSelectionResponse {
                ok: false,
                model: Some(OPENAI_DEFAULT_MODEL.to_string()),
                reasoning_effort: Some(ReasoningEffort::Medium.to_string()),
                active_profile: None,
                error: Some(err),
            },
        }
    })
    .join()
    .unwrap_or_else(|panic| ModelSelectionResponse {
        ok: false,
        model: Some(OPENAI_DEFAULT_MODEL.to_string()),
        reasoning_effort: Some(ReasoningEffort::Medium.to_string()),
        active_profile: None,
        error: Some(format!("thread panic: {panic:?}")),
    });

    selection_response_json(response)
}

/// Read the effective approval policy and sandbox mode from Codex config.
#[unsafe(no_mangle)]
pub extern "C" fn codex_get_approval_sandbox_json(cwd: *const c_char) -> *mut c_char {
    let cwd_str = c_optional_string(cwd)
        .ok()
        .flatten()
        .unwrap_or_else(|| ".".to_string());

    let response = std::thread::spawn(move || -> ApprovalSandboxResponse {
        let rt = match Runtime::new() {
            Ok(rt) => rt,
            Err(err) => {
                return ApprovalSandboxResponse {
                    ok: false,
                    approval_policy: None,
                    sandbox_mode: None,
                    error: Some(format!("runtime: {err}")),
                };
            }
        };

        match rt.block_on(load_config_with_optional_overrides(
            &cwd_str, None, None, None, None,
        )) {
            Ok(config) => ApprovalSandboxResponse {
                ok: true,
                approval_policy: Some(config.approval_policy.to_string()),
                sandbox_mode: Some(sandbox_mode_for_policy(&config.sandbox_policy).to_string()),
                error: None,
            },
            Err(err) => ApprovalSandboxResponse {
                ok: false,
                approval_policy: None,
                sandbox_mode: None,
                error: Some(err),
            },
        }
    })
    .join()
    .unwrap_or_else(|panic| ApprovalSandboxResponse {
        ok: false,
        approval_policy: None,
        sandbox_mode: None,
        error: Some(format!("thread panic: {panic:?}")),
    });

    approval_sandbox_response_json(response)
}

/// Read built-in model presets from the shared TUI model catalog.
#[unsafe(no_mangle)]
pub extern "C" fn codex_get_model_presets_json() -> *mut c_char {
    let presets = builtin_model_presets(None)
        .into_iter()
        .map(|preset| ModelPresetResponse {
            id: preset.id.to_string(),
            model: preset.model.to_string(),
            display_name: preset.display_name.to_string(),
            description: preset.description.to_string(),
            default_reasoning_effort: preset.default_reasoning_effort.to_string(),
            supported_reasoning_efforts: preset
                .supported_reasoning_efforts
                .iter()
                .map(|option| ReasoningEffortPresetResponse {
                    effort: option.effort.to_string(),
                    description: option.description.to_string(),
                })
                .collect(),
            is_default: preset.is_default,
        })
        .collect();

    model_presets_response_json(ModelPresetsResponse {
        ok: true,
        presets,
        error: None,
    })
}

/// Read configured MCP servers with live tool/resource/auth status.
#[unsafe(no_mangle)]
pub extern "C" fn codex_get_mcp_status_json(cwd: *const c_char) -> *mut c_char {
    let cwd_str = c_optional_string(cwd)
        .ok()
        .flatten()
        .unwrap_or_else(|| ".".to_string());

    let response = std::thread::spawn(move || -> McpStatusResponse {
        let rt = match Runtime::new() {
            Ok(rt) => rt,
            Err(err) => {
                return McpStatusResponse {
                    ok: false,
                    servers: Vec::new(),
                    errors: Vec::new(),
                    error: Some(format!("runtime: {err}")),
                };
            }
        };

        match rt.block_on(load_mcp_status(&cwd_str)) {
            Ok(status) => status,
            Err(err) => McpStatusResponse {
                ok: false,
                servers: Vec::new(),
                errors: Vec::new(),
                error: Some(err),
            },
        }
    })
    .join()
    .unwrap_or_else(|panic| McpStatusResponse {
        ok: false,
        servers: Vec::new(),
        errors: Vec::new(),
        error: Some(format!("thread panic: {panic:?}")),
    });

    mcp_status_response_json(response)
}

/// Persist the selected model + effort using the same semantics as the TUI.
#[unsafe(no_mangle)]
pub extern "C" fn codex_persist_model_selection_json(
    cwd: *const c_char,
    model: *const c_char,
    reasoning_effort: *const c_char,
) -> *mut c_char {
    let cwd_str = c_optional_string(cwd)
        .ok()
        .flatten()
        .unwrap_or_else(|| ".".to_string());

    let model = match c_required_string(model, "model") {
        Ok(value) => value,
        Err(err) => {
            return selection_response_json(ModelSelectionResponse {
                ok: false,
                model: None,
                reasoning_effort: None,
                active_profile: None,
                error: Some(err),
            });
        }
    };

    let effort = match c_optional_string(reasoning_effort)
        .and_then(|raw| parse_reasoning_effort(raw.as_deref()))
    {
        Ok(value) => value,
        Err(err) => {
            return selection_response_json(ModelSelectionResponse {
                ok: false,
                model: Some(model),
                reasoning_effort: None,
                active_profile: None,
                error: Some(err),
            });
        }
    };

    let model_for_thread = model.clone();
    let response = std::thread::spawn(move || -> ModelSelectionResponse {
        let rt = match Runtime::new() {
            Ok(rt) => rt,
            Err(err) => {
                return ModelSelectionResponse {
                    ok: false,
                    model: Some(model_for_thread),
                    reasoning_effort: effort.map(|value| value.to_string()),
                    active_profile: None,
                    error: Some(format!("runtime: {err}")),
                };
            }
        };

        let result = rt.block_on(async {
            let config = load_config_with_optional_overrides(
                &cwd_str,
                Some(model_for_thread.clone()),
                effort,
                None,
                None,
            )
            .await?;

            let active_profile = config.active_profile.clone();
            persist_model_selection(
                &config.codex_home,
                active_profile.as_deref(),
                &model_for_thread,
                effort,
            )
            .await
            .map_err(|err| format!("persist: {err}"))?;

            Ok::<Option<String>, String>(active_profile)
        });

        match result {
            Ok(active_profile) => ModelSelectionResponse {
                ok: true,
                model: Some(model_for_thread),
                reasoning_effort: effort.map(|value| value.to_string()),
                active_profile,
                error: None,
            },
            Err(err) => ModelSelectionResponse {
                ok: false,
                model: Some(model_for_thread),
                reasoning_effort: effort.map(|value| value.to_string()),
                active_profile: None,
                error: Some(err),
            },
        }
    })
    .join()
    .unwrap_or_else(|panic| ModelSelectionResponse {
        ok: false,
        model: Some(model),
        reasoning_effort: effort.map(|value| value.to_string()),
        active_profile: None,
        error: Some(format!("thread panic: {panic:?}")),
    });

    selection_response_json(response)
}

/// Free strings returned by this FFI.
#[unsafe(no_mangle)]
pub extern "C" fn codex_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(value);
    }
}

/// Cancel the current operation.
#[unsafe(no_mangle)]
pub extern "C" fn codex_cancel(handle: *mut CodexHandle) {
    if handle.is_null() {
        return;
    }
    let handle = unsafe { &*handle };
    handle.cancelled.store(true, Ordering::SeqCst);
    let conversation = handle.conversation.clone();
    handle.runtime.block_on(async {
        let _ = conversation.submit(Op::Interrupt).await;
    });
}

/// Destroy a codex session and free resources.
#[unsafe(no_mangle)]
pub extern "C" fn codex_destroy(handle: *mut CodexHandle) {
    if !handle.is_null() {
        let handle = unsafe { Box::from_raw(handle) };
        handle.runtime.block_on(async {
            let _ = handle.conversation.submit(Op::Shutdown).await;
        });
        drop(handle);
    }
}
