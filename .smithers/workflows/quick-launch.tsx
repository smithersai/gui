// smithers-source: seeded
// smithers-display-name: Quick Launch
/** @jsxImportSource smithers-orchestrator */
import { createSmithers } from "smithers-orchestrator";
import { z } from "zod/v4";
import { providers } from "../agents";
import QuickLaunchPrompt from "../prompts/quick-launch.mdx";

const inputSchema = z.object({
  target: z.string().describe("Name of the target workflow to launch"),
  prompt: z.string().default("").describe("User's natural-language prompt"),
  schema: z.string().default("[]").describe("JSON array describing the target workflow's input fields"),
});

const parseOutputSchema = z.object({
  inputs: z.record(z.string(), z.unknown()).default({}),
  notes: z.string().default(""),
}).passthrough();

// Preference order for a small/fast/cheap model: kimi → gemini → claudeSonnet → codex.
const parseAgents = [
  providers.kimi,
  providers.gemini,
  providers.claudeSonnet,
  providers.codex,
];

const { Workflow, Task, smithers } = createSmithers({
  input: inputSchema,
  parse: parseOutputSchema,
});

export default smithers((ctx) => (
  <Workflow name="quick-launch">
    <Task id="parse" output={parseOutputSchema} agent={parseAgents}>
      <QuickLaunchPrompt
        target={ctx.input.target}
        prompt={ctx.input.prompt}
        schema={ctx.input.schema}
      />
    </Task>
  </Workflow>
));
