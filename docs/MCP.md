# MCP server

Meeting Transcriber exposes a local [Model Context Protocol](https://modelcontextprotocol.io)
server while the app is running so Claude Code (or any other MCP-aware
client on the same Mac) can list, read, filter, and tag your transcripts.

## What it is

- **Where it runs:** in-process inside Meeting Transcriber, on a tiny
  HTTP listener at `http://127.0.0.1:47823/mcp`.
- **Started/stopped with the app.** No menu toggle, no settings UI.
  Quit the app and the endpoint goes away.
- **Localhost only.** The listener is bound to the loopback interface,
  and the MCP transport rejects requests whose `Origin` header isn't
  localhost. Other devices on your network cannot reach it.
- **Mostly read-only.** Tools cannot record, delete, or summarize. The
  `set_tags` tool can replace a transcript's tag list through the running
  app, and persists the updated transcript JSON/Markdown.

## Tools

| Tool | Args | Returns |
| --- | --- | --- |
| `list_transcripts` | `query` (optional substring on title), `tags` (optional array; transcript must contain all listed tags) | JSON array of `{ id, title, date, durationSeconds, language, hasSummary, tags }`, newest first |
| `list_tags` | none | JSON array of `{ name, color, count }`, sorted by usage count |
| `get_transcript` | `id` (required) | The full markdown transcript |
| `get_summary` | `id` (required) | Markdown with the LLM summary, action items, and the model + timestamp. Errors if the transcript hasn't been summarized yet. |
| `set_tags` | `id` (required), `tags` (required array) | Replaces the transcript's full tag list and returns `{ id, tags }`. Unknown tag names are auto-created in the managed catalog. |

`set_tags` uses replace semantics: to add one tag, first read the current
`tags` field from `list_transcripts`, append the new tag client-side, then
send the complete replacement list.

## Connecting Claude Code

Once, from any directory:

```sh
claude mcp add --transport http meeting-transcriber http://127.0.0.1:47823/mcp
```

Verify:

```sh
claude mcp list
```

You should see `meeting-transcriber` and, while the app is running,
its status as connected. Inside a Claude Code session you can then
ask things like:

- "Find my meeting with Acme last week and summarize the action items."
- "Pull the transcript of `<title>` and quote the part where we discussed pricing."
- "List my available tags, then show transcripts tagged `Client`."
- "Set the tags on transcript `<id>` to `Client` and `Follow-up`."

If the app isn't running, Claude Code will mark the server as down —
launch Meeting Transcriber and re-run the request.

### Project-scoped alternative

If you'd rather have Claude Code register it per-project, drop a
`.mcp.json` at your repo root:

```json
{
  "mcpServers": {
    "meeting-transcriber": {
      "type": "http",
      "url": "http://127.0.0.1:47823/mcp"
    }
  }
}
```

## Smoke test without a client

Curl the `tools/list` method directly:

```sh
curl -sS http://127.0.0.1:47823/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -H 'Origin: http://localhost' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

A healthy response is a JSON-RPC envelope listing the five tools
above.

## Limits and non-goals

- **Stateless transport.** No server-initiated notifications, no SSE,
  no session resumption. Each tool call is one round-trip.
- **No auth.** The localhost-only binding is the only fence. Don't
  open the port in a firewall or expose it through a tunnel without
  adding a bearer token first.
- **Fixed port.** If `47823` is already taken by another process, the
  listener fails silently and the rest of the app keeps working —
  check `Console.app` for an `MCP: NWListener init failed` line.
