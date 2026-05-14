# claude-code-rich-statusline

A custom statusline for [Claude Code](https://docs.anthropic.com/claude/docs/claude-code) that shows:

```
Opus 4.7 (1M context) | development | Context 17% | Session 39% | Resets in 2h 9m
```

| Segment | What it is | Source |
|---|---|---|
| Model | `model.display_name` from the statusline stdin | Claude Code |
| Dir | Basename of the current working dir | Claude Code |
| **Context %** | Tokens in this conversation vs. the model's context window (1M or 200k) | Transcript file (`message.usage` of the latest assistant turn) |
| **Session %** | Utilization of your Anthropic 5h API window | `anthropic-ratelimit-unified-5h-utilization` response header |
| **Resets in** | Time until the 5h window rolls over | `anthropic-ratelimit-unified-5h-reset` response header |

Authoritative session/reset values — same numbers you'd see in Claude Code's `/usage` dialog, fetched directly from Anthropic's headers (not heuristics, not `ccusage`).

## How it works

The two ratelimit numbers come from Anthropic's response headers on a real `/v1/messages` call. The script:

1. Reads your OAuth token from the macOS keychain entry `Claude Code-credentials`.
2. Makes a tiny `claude-haiku-4-5` call (`max_tokens: 1`) in the background.
3. Parses the `anthropic-ratelimit-unified-5h-reset` and `anthropic-ratelimit-unified-5h-utilization` headers.
4. Caches them in `~/.claude/statusline-cache/api-state.env` and re-uses for ~5 min.

Context % is computed inline (no network call) by scanning the transcript file passed via stdin and summing `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` from the latest assistant `message.usage`.

Foreground render is ~30-50 ms. The curl refresh runs in a backgrounded subshell guarded by a `mkdir`-based lock so the prompt never blocks on the network.

## Install

1. Drop the script wherever you want and make it executable:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/lanche86/claude-code-rich-statusline/main/statusline-command.sh \
     -o ~/.claude/statusline-command.sh
   chmod +x ~/.claude/statusline-command.sh
   ```

2. Point Claude Code at it in `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "/Users/YOUR_USERNAME/.claude/statusline-command.sh"
     }
   }
   ```

3. Allow the script to read the keychain credential. Add to the `permissions.allow` array in `~/.claude/settings.json`:

   ```json
   "Bash(security find-generic-password:*)"
   ```

4. Restart Claude Code (or start a new session).

## Requirements

- macOS (uses `security find-generic-password` for keychain access)
- `bash`, `curl`, `jq`, `awk` — all default on macOS
- A Claude Code login that has stored an OAuth token in the keychain

## Gotchas worth knowing

- `/v1/messages/count_tokens` does **not** return the `anthropic-ratelimit-unified-*` headers — only real inference does. That's why this script hits `/v1/messages` (the cheapest possible call: haiku + `max_tokens: 1`).
- The bearer call needs the beta header `anthropic-beta: oauth-2025-04-20`. Without it, Anthropic rejects the request.
- The keychain read happens inside Claude Code's permission model, so the `Bash(security find-generic-password:*)` rule above is required.
- Each refresh consumes a few haiku tokens — effectively free at current haiku pricing, but it does count against your own Session % (you'll see it tick up by a tiny amount when the cache refreshes).

## Configuration

Most of the behavior is controlled by constants near the top of the script (refresh interval, context-window detection, color codes). Edit and re-save — no restart needed; Claude Code re-executes the script on every prompt.

## License

[MIT](./LICENSE)
