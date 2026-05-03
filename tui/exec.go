package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/williamcory/agent/sdk/agent"
	"github.com/williamcory/agent/tui/internal/embedded"
)

var stderr = os.Stderr

// ExecFlags contains command-line flags for the exec command.
type ExecFlags struct {
	file        string
	model       string
	directory   string
	timeout     int
	full        bool
	jsonOutput  bool
	stream      bool
	noTools     bool
	quiet       bool
	backendURL  string
	useEmbedded bool
}

// parseExecFlags parses command-line flags for the exec command.
func parseExecFlags(args []string) (*ExecFlags, []string, error) {
	flags := &ExecFlags{}
	fs := flag.NewFlagSet("exec", flag.ContinueOnError)
	fs.SetOutput(stderr)

	fs.StringVar(&flags.file, "f", "", "Read prompt from file")
	fs.StringVar(&flags.file, "file", "", "Read prompt from file")
	fs.StringVar(&flags.model, "m", "", "Model to use")
	fs.StringVar(&flags.model, "model", "", "Model to use")
	fs.StringVar(&flags.directory, "C", "", "Working directory")
	fs.StringVar(&flags.directory, "cd", "", "Working directory")
	fs.IntVar(&flags.timeout, "timeout", 0, "Timeout in seconds (0 = no timeout)")
	fs.BoolVar(&flags.full, "full", false, "Include all messages in output")
	fs.BoolVar(&flags.jsonOutput, "json", false, "Output in JSON format")
	fs.BoolVar(&flags.stream, "stream", false, "Stream output in real-time")
	fs.BoolVar(&flags.noTools, "no-tools", false, "Disable tool execution")
	fs.BoolVar(&flags.quiet, "q", false, "Suppress status messages")
	fs.BoolVar(&flags.quiet, "quiet", false, "Suppress status messages")
	fs.StringVar(&flags.backendURL, "backend", "", "Backend URL (overrides embedded server)")
	fs.BoolVar(&flags.useEmbedded, "embedded", true, "Use embedded server (default: true)")

	if err := fs.Parse(args); err != nil {
		return nil, nil, err
	}

	return flags, fs.Args(), nil
}

// readPrompt reads the prompt from various sources.
func readPrompt(flags *ExecFlags, args []string) (string, error) {
	var prompt string

	// Priority 1: Command line argument
	if len(args) > 0 {
		prompt = strings.Join(args, " ")
	}

	// Priority 2: File input (overrides command line)
	if flags.file != "" {
		data, err := os.ReadFile(flags.file)
		if err != nil {
			return "", fmt.Errorf("read prompt file: %w", err)
		}
		prompt = string(data)
	}

	// Priority 3: Stdin (only if no other input and stdin is piped)
	if prompt == "" {
		stat, err := os.Stdin.Stat()
		if err == nil && (stat.Mode()&os.ModeCharDevice) == 0 {
			data, err := io.ReadAll(os.Stdin)
			if err != nil {
				return "", fmt.Errorf("read stdin: %w", err)
			}
			prompt = string(data)
		}
	}

	prompt = strings.TrimSpace(prompt)
	if prompt == "" {
		return "", fmt.Errorf("no prompt provided (use argument, -f flag, or stdin)")
	}

	return prompt, nil
}

// execCommand implements the non-interactive exec command.
func execCommand(args []string) int {
	// Parse flags
	flags, promptArgs, err := parseExecFlags(args)
	if err != nil {
		if err != flag.ErrHelp {
			fmt.Fprintf(stderr, "Error parsing flags: %v\n", err)
		}
		return 2
	}

	// Read prompt
	prompt, err := readPrompt(flags, promptArgs)
	if err != nil {
		fmt.Fprintf(stderr, "Error: %v\n", err)
		return 2
	}

	// Determine output format
	format := "text"
	if flags.jsonOutput {
		format = "json"
	} else if flags.stream {
		format = "stream"
	}

	// Create output formatter
	formatter := NewOutputFormatter(format, flags.full, flags.quiet)

	// Initialize logger
	logger := agent.NewLoggerFromEnv()
	agent.SetLogger(logger)

	// Determine backend URL
	url := flags.backendURL
	if url == "" {
		url = os.Getenv("OPENCODE_SERVER")
	}

	var serverProcess *embedded.ServerProcess
	var cleanup func()

	// Start embedded server if needed
	if url == "" && flags.useEmbedded {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()

		formatter.StatusMessage("Starting embedded server...")
		var err error
		serverProcess, url, err = embedded.StartServerWithLoggerQuiet(ctx, logger, flags.quiet)
		if err != nil {
			fmt.Fprintf(stderr, "Error starting embedded server: %v\n", err)
			fmt.Fprintf(stderr, "Tip: Use --backend=URL to connect to an external server\n")
			return 2
		}

		cleanup = func() {
			if serverProcess != nil {
				serverProcess.Stop()
			}
		}
		defer cleanup()
	} else if url == "" {
		url = "http://localhost:8000"
	}

	// Determine working directory
	cwd := flags.directory
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			fmt.Fprintf(stderr, "Error getting working directory: %v\n", err)
			return 2
		}
	}

	// Create SDK client
	clientOpts := []agent.ClientOption{
		agent.WithDirectory(cwd),
		agent.WithLogger(logger),
	}
	if flags.timeout > 0 {
		clientOpts = append(clientOpts, agent.WithTimeout(time.Duration(flags.timeout)*time.Second))
	}
	client := agent.NewClient(url, clientOpts...)

	// Create context with timeout if specified
	ctx := context.Background()
	var cancel context.CancelFunc
	if flags.timeout > 0 {
		ctx, cancel = context.WithTimeout(ctx, time.Duration(flags.timeout)*time.Second)
		defer cancel()
	} else {
		ctx, cancel = context.WithCancel(ctx)
		defer cancel()
	}

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		formatter.StatusMessage("Received interrupt signal, canceling...")
		cancel()
	}()

	// Execute the agent task
	exitCode := runAgent(ctx, client, prompt, flags, formatter)

	// Cleanup
	signal.Stop(sigChan)

	return exitCode
}

// runAgent runs the agent with the given prompt and returns an exit code.
func runAgent(ctx context.Context, client *agent.Client, prompt string, flags *ExecFlags, formatter *OutputFormatter) int {
	// Create session
	formatter.StatusMessage("Creating session...")
	session, err := client.CreateSession(ctx, nil)
	if err != nil {
		fmt.Fprintf(stderr, "Error creating session: %v\n", err)
		formatter.SetError(err)
		formatter.Finalize()
		return 1
	}

	// Add user message to output
	formatter.AddUserMessage(prompt)

	// Build prompt request
	req := &agent.PromptRequest{
		Parts: []interface{}{
			agent.TextPartInput{Type: "text", Text: prompt},
		},
	}

	if flags.noTools {
		req.Tools = map[string]bool{"*": false}
	}

	// Set model if specified
	if flags.model != "" {
		// Parse model string (format: "provider/model" or just "model")
		parts := strings.SplitN(flags.model, "/", 2)
		if len(parts) == 2 {
			req.Model = &agent.ModelInfo{
				ProviderID: parts[0],
				ModelID:    parts[1],
			}
		} else {
			// Try to find matching model from providers
			providers, err := client.ListProviders(ctx)
			if err == nil {
				for _, provider := range providers.Providers {
					for _, model := range provider.Models {
						if model.ID == flags.model || model.Name == flags.model {
							req.Model = &agent.ModelInfo{
								ProviderID: provider.ID,
								ModelID:    model.ID,
							}
							break
						}
					}
					if req.Model != nil {
						break
					}
				}
			}
		}
	}

	// Send message and stream response
	formatter.StatusMessage("Sending message...")
	eventCh, errCh, err := client.SendMessage(ctx, session.ID, req)
	if err != nil {
		fmt.Fprintf(stderr, "Error sending message: %v\n", err)
		formatter.SetError(err)
		formatter.Finalize()
		return 1
	}

	// Process streaming events
	var currentText strings.Builder
	var finalMessage *agent.Message
	seenTools := make(map[string]bool)
	textParts := make(map[string]string) // Track text parts by ID

	for {
		select {
		case <-ctx.Done():
			err := ctx.Err()
			if err == context.DeadlineExceeded {
				fmt.Fprintf(stderr, "Error: operation timed out\n")
			} else if err != context.Canceled {
				fmt.Fprintf(stderr, "Error: %v\n", err)
			}
			formatter.SetError(err)
			formatter.Finalize()
			return 1

		case err, ok := <-errCh:
			if ok && err != nil {
				fmt.Fprintf(stderr, "Error: %v\n", err)
				formatter.SetError(err)
			}
			// Add accumulated text as a single assistant message before finalizing
			if currentText.Len() > 0 {
				formatter.AddAssistantMessage(currentText.String())
			}
			formatter.Finalize()
			if err != nil {
				return 1
			}
			return 0

		case event, ok := <-eventCh:
			if !ok {
				// Stream completed successfully
				// Add accumulated text as a single assistant message
				if currentText.Len() > 0 {
					formatter.AddAssistantMessage(currentText.String())
				}
				if finalMessage != nil && finalMessage.Tokens != nil {
					formatter.SetTokensUsed(GetTokensFromMessage(finalMessage))
				}
				formatter.Finalize()
				return 0
			}

			// Process the event
			if event.Message != nil && event.Message.IsAssistant() {
				finalMessage = event.Message
			}

			if event.Part != nil {
				switch event.Part.Type {
				case "text":
					// Accumulate text parts instead of resetting
					// Check if this is a new part or an update
					if prevText, exists := textParts[event.Part.ID]; !exists || prevText != event.Part.Text {
						textParts[event.Part.ID] = event.Part.Text
						// Rebuild currentText from all parts
						currentText.Reset()
						currentText.WriteString(event.Part.Text)
					}
					formatter.StreamText(event.Part.Text)

				case "tool":
					if event.Part.State != nil {
						toolKey := event.Part.ID + ":" + event.Part.State.Status
						if !seenTools[toolKey] {
							seenTools[toolKey] = true

							switch event.Part.State.Status {
							case "pending", "running":
								formatter.StreamToolCall(event.Part.Tool, event.Part.State.Input)

							case "completed":
								formatter.StreamToolResult(event.Part.State.Output)
								formatter.AddToolCall(event.Part.Tool, event.Part.State.Input, event.Part.State.Output)
							}
						}
					}
				}
			}
		}
	}
}
