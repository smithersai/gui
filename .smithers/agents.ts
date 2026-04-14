// smithers-source: generated
import { ClaudeCodeAgent, CodexAgent, GeminiAgent, PiAgent, KimiAgent, AmpAgent, type AgentLike } from "smithers-orchestrator";

export const providers = {
  claude: new ClaudeCodeAgent({ model: "claude-opus-4-6" }),
  codex: new CodexAgent({ model: "gpt-5.3-codex", skipGitRepoCheck: true }),
  gemini: new GeminiAgent({ model: "gemini-3.1-pro-preview" }),
  pi: new PiAgent({ provider: "openai", model: "gpt-5.3-codex" }),
  kimi: new KimiAgent({ model: "kimi-latest" }),
  amp: new AmpAgent(),
  claudeSonnet: new ClaudeCodeAgent({ model: "claude-sonnet-4-6" }),
} as const;

export const agents = {
  cheapFast: [providers.kimi, providers.claudeSonnet],
  smart: [providers.codex, providers.claude, providers.kimi],
  smartTool: [providers.claude, providers.codex, providers.kimi],
} as const satisfies Record<string, AgentLike[]>;
