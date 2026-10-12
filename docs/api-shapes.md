# Worklens — Verified API shapes

Moved from `docs/PLAN.md` §2 on 2026-09-08. Do not re-derive these from memory; they were
checked with live calls on 2026-09-07. Read this when touching `GeminiClient`. The Anthropic
Messages API shape went with the reports on 2026-10-05; Worklens calls no Anthropic endpoint.

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
