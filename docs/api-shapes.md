# Worklens — Verified API shapes

Moved from `docs/PLAN.md` §2 on 2026-09-08. Do not re-derive these from memory; they were
checked with live calls on 2026-09-07. Read this when touching `GeminiClient`. The Anthropic
Messages API shape went with the reports on 2026-10-05. Worklens still calls no Anthropic or
OpenAI endpoint itself: a Claude or ChatGPT plan is reached through the person's own signed-in
`claude` and `codex` commands, whose shapes are at the end of this page.

**Gemini** — `POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent`,
header `x-goog-api-key`. Confirmed with a live call on 2026-09-07 (HTTP 200):

```json
{
  "systemInstruction": {"parts": [{"text": "..."}]},
  "contents": [{"role": "user", "parts": [
    {"inline_data": {"mime_type": "image/jpeg", "data": "<base64>"}},
    {"text": "..."}
  ]}],
  "generationConfig": {
    "thinkingConfig": {"thinkingLevel": "minimal"},
    "mediaResolution": "MEDIA_RESOLUTION_MEDIUM",
    "responseMimeType": "application/json",
    "responseJsonSchema": { "...JSON Schema..." },
    "maxOutputTokens": 400,
    "temperature": 0.2
  }
}
```
Response: `candidates[0].content.parts[].text` (ignore `thoughtSignature`),
`usageMetadata.{promptTokenCount,candidatesTokenCount,thoughtsTokenCount,totalTokenCount,promptTokensDetails[]}`.
Image cost: `MEDIA_RESOLUTION_LOW` ≈ 256–280 tokens, `MEDIUM` 560, `HIGH` 1120. **Unspecified defaults to 1120 — always set it.**
Free tier data may be used for training by Google; the paid tier is not. **Use a billing-enabled project.**

**A nullable enum in `responseJsonSchema`** (prompt `d5`, #315), checked live on 2026-10-07
against `gemini-3.5-flash-lite`: a property whose `type` is a list including `"null"` and whose
`enum` ends in a JSON `null` is accepted (HTTP 200). The model returned `null` when no listed
key fit, and the listed key when one did:

```json
"project_key": {"type": ["string", "null"], "enum": ["acme", "firm", null],
                "description": "..."}
```
`project_key` is optional (not in `required`) and is left out of the schema entirely when the
catalog is empty.

**A batch** (prompt `d6`, `SUMMARY_BATCH`; built here, not checked live): the same request, with
`contents[0].parts` holding the prompt text first and then, for each picture, a `text` part with
its label (`Screenshot 3 of 7, 14:32:10`) followed by its `inline_data` part. The schema wraps one
screenshot's properties in an array, each entry with an `id` enum of the batch's capture ids:
`{"type":"object","properties":{"screenshots":{"type":"array","items":{…,"properties":{"id":…}}}},"required":["screenshots"]}`.
`claude -p` gets the same label-then-image blocks on stdin; `codex exec` gets one `--image=` per
picture, in prompt order.

**MCP** — what Worklens' own server speaks, checked against the 2025-06-18 revision on
2026-09-18 and the 2025-11-25 lifecycle page on 2026-09-24. `initialize` echoes the client's
`protocolVersion` when it is one of those two and answers `2025-11-25` otherwise, and returns
`capabilities: {"tools": {}, "prompts": {}}`, an `instructions` string naming the data directory
and what to ask about, and the app icon in `serverInfo` (sent under either
version; an older client ignores it):

```json
"serverInfo":{"name":"worklens","version":"…",
  "icons":[{"src":"data:image/png;base64,…","mimeType":"image/png","sizes":["64x64"]}]}
```

```json
{"jsonrpc":"2.0","id":1,"method":"prompts/list"}
{"result":{"prompts":[{"name":"how_was_today","title":"How did today go?",
  "description":"...","arguments":[{"name":"day","description":"...","required":false}]}]}}

{"jsonrpc":"2.0","id":2,"method":"prompts/get",
 "params":{"name":"how_was_today","arguments":{"day":"2026-09-17"}}}
{"result":{"description":"...","messages":[
  {"role":"user","content":{"type":"text","text":"..."}}]}}
```

A `tools/list` entry carries `name`, `title`, `description`, `inputSchema` and
`annotations: {"readOnlyHint": true, "openWorldHint": false, "idempotentHint": true}` — the three
hints a client reads to show a read-only badge. Worklens sets the same three on every tool.

**`claude -p`, the Claude summarizer** (`LLM/ClaudeDescriber.swift`). Checked with live calls
against Claude Code 2.1.326 on a team plan on 2026-11-27. The argv carries no screen content:

```
claude -p --input-format stream-json --output-format stream-json --verbose
  --model sonnet --effort low --system-prompt <instruction>
  --tools "" --strict-mcp-config --setting-sources "" --settings {"autoMemoryEnabled":false}
  --no-session-persistence --disable-slash-commands --json-schema <schema without project names>
```
stdin is one line, `{"type":"user","message":{"role":"user","content":[{"type":"text",…},
{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"…"}}]}}`. The working
directory is the empty `DATA_DIR/run/cli-empty`, and the environment is HOME, USER, LOGNAME, PATH,
LANG and TMPDIR only: without USER the command reads no sign-in and answers "Not logged in".

- The `init` event shows `tools: ["StructuredOutput"]`, `mcp_servers: []`, `apiKeySource: "none"`,
  `skills: []`, `slash_commands: []`. A live call told to read a canary file in that folder could
  not. `--settings {"autoMemoryEnabled":false}` removes `memory_paths` and still runs on the plan.
- **`--bare` is not usable**: it is the only flag that also drops the built-in plugins, and it
  turns the plan's sign-in off ("Not logged in"). The built-in plugins still load; with no tools
  they have nothing to act on.
- The `result` event: `subtype`, `is_error`, `result` (text), `structured_output` (the answer,
  matching `--json-schema`), `usage.{input_tokens, cache_creation_input_tokens,
  cache_read_input_tokens, output_tokens}`, `modelUsage.{<model id>: {outputTokens, …}}`,
  `api_error_status`. `total_cost_usd` is what the call would have cost on the API; on a plan
  Worklens records $0.
- `rate_limit_event.rate_limit_info`: `status` (`allowed`/`rejected`), `resetsAt` (epoch seconds),
  `unifiedWindows.{five_hour, seven_day}.{utilization 0–1, resetsAt, status}`.
- `claude auth status --json`: `loggedIn`, `authMethod` (`claude.ai` for a plan, `api_key`
  otherwise), `subscriptionType`, `loginExpiresAt` (ISO 8601). Worklens reads nothing else from
  it, and never the keychain or a credentials file.
- The `project_key` enum is stripped from the `--json-schema` argument, because argv is visible to
  every process on the Mac; the descriptions name no project, and the taxonomy resolves the key.

**`codex exec`, the ChatGPT summarizer** (`LLM/CodexDescriber.swift`). Checked against codex-cli
0.159.3 on 2026-11-27. The sign-in on this Mac was stale, so a successful summary was **not**
seen live; the failure shape below was.

```
codex exec --image=<screenshot.jpg> --json --ephemeral --ignore-user-config --ignore-rules
  --skip-git-repo-check -s read-only -C <DATA_DIR/run/cli-empty> [-m gpt-6.1-sol]
  -c model_reasoning_effort="low" -c developer_instructions=<instruction as a JSON string>
  -c web_search="disabled" -c approval_policy="never" -c project_doc_max_bytes=0
  -c history.persistence="none" -c include_permissions_instructions=false
  -c skills.include_instructions=false -c skills.bundled.enabled=false
  --disable shell_tool --disable unified_exec … (15 features) --output-schema <file, 0600> -
```
The trailing `-` reads the prompt from stdin. `--output-schema` needs a strict schema: every
property in `required`, the optional ones nullable, `additionalProperties: false`.

- Events, one per line: `thread.started`, `turn.started`, `item.completed` (the answer is the last
  `item.type == "agent_message"`, in `item.text`), `turn.completed.usage.{input_tokens,
  cached_input_tokens, output_tokens, reasoning_output_tokens}`.
- A stale sign-in: several `{"type":"error","message":"Reconnecting… (workspace routing discovery
  unauthorized (401))"}`, then `{"type":"turn.failed","error":{"message":"…unauthorized (401)"}}`,
  with "refresh token was revoked" on stderr, while `codex login status` still says "Logged in
  using ChatGPT". So a 401 on a call is treated as signed out whatever the status said.
- `codex debug models` prints `{"models":[{"slug", "visibility", "input_modalities", …}]}`. On
  2026-11-27 the listed, image-reading entries included `gpt-6-astra`, `gpt-6.1-sol`,
  `gpt-6-sol`, `gpt-6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` and `gpt-5.5`;
  `sol` resolves to `gpt-6.1-sol`. `codex login status` prints "Logged in using ChatGPT" or
  "… an API key" (on stderr in this version).
