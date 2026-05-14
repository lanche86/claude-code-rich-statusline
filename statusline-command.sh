#!/usr/bin/env bash
# Claude Code statusline.
#
# Layout:
#   <model> | <dir> | Context X% | Session Y% | Resets in Zh Wm
#
# Data sources
# ------------
# Context X%:
#   Sum of input + cache_read + cache_creation from the LATEST assistant
#   `message.usage` in $transcript_path. Divided by the model's context window
#   (1M if display_name contains "1M", else 200k). Computed inline — jq scan
#   of the transcript is ~15ms.
#
# Session Y% and "Resets in":
#   Authoritative — taken from Anthropic response headers on a real
#   /v1/messages call:
#     anthropic-ratelimit-unified-5h-utilization  (e.g. "0.39")
#     anthropic-ratelimit-unified-5h-reset        (unix epoch seconds)
#   Note: /v1/messages/count_tokens does NOT return these headers; only real
#   inference does. We use claude-haiku-4-5 with max_tokens=1 to keep the call
#   cheap (~$0 with current haiku pricing) but the call DOES count against your
#   own unified 5h window (adds a few tokens to Session %).
#
# Auth
# ----
# OAuth token is read from the macOS keychain:
#   security find-generic-password -s "Claude Code-credentials" -w
# The value is JSON; .claudeAiOauth.accessToken is the bearer token.
# When calling /v1/messages with this token you MUST send the beta header
#   anthropic-beta: oauth-2025-04-20
# otherwise the request is rejected.
#
# Caching
# -------
# ~/.claude/statusline-cache/api-state.env holds RESET_EPOCH=... and
# UTILIZATION=... in shell-source format. Refresh triggers (async, lock-guarded):
#   - cache missing or older than 5 minutes
#   - cached RESET_EPOCH is already in the past (window rolled over)
# The locking is a `mkdir` directory; a stale lock older than 2 minutes is
# reaped so a crashed prior refresh can't wedge things.
#
# Performance
# -----------
# Foreground render is ~30-50ms (jq scan + cache read). The curl refresh runs
# in the background and never blocks the prompt.

input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
model=$(echo "$input" | jq -r '.model.display_name // .model.id // ""')
transcript=$(echo "$input" | jq -r '.transcript_path // ""')

dir=$(basename "$cwd")

# Context %: tokens in latest assistant usage / model context window
context_segment=""
if [ -f "$transcript" ]; then
  total_tokens=$(jq -s '
    [ .[] | select(.type=="assistant" and .message.usage != null) | .message.usage ]
    | if length > 0
      then last | (.input_tokens + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
      else 0 end' "$transcript" 2>/dev/null)
  if [[ "$total_tokens" =~ ^[0-9]+$ ]] && [ "$total_tokens" -gt 0 ]; then
    if [[ "$model" == *"1M"* ]]; then
      limit=1000000
    else
      limit=200000
    fi
    pct=$(( total_tokens * 100 / limit ))
    context_segment="Context ${pct}%"
  fi
fi

MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
DIM='\033[2m'
RESET='\033[0m'

CACHE_DIR="${HOME}/.claude/statusline-cache"
API_FILE="${CACHE_DIR}/api-state.env"
LOCK_FILE="${CACHE_DIR}/api-state.lock"
mkdir -p "$CACHE_DIR"

# Defaults so unset shell vars don't trip set -u (we don't set -u, but be explicit)
RESET_EPOCH=0
UTILIZATION=""
# shellcheck disable=SC1090
[ -s "$API_FILE" ] && . "$API_FILE"

# Reap a stale lock from a crashed prior refresh (older than 2 min)
if [ -d "$LOCK_FILE" ]; then
  lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))
  [ "$lock_age" -gt 120 ] && rmdir "$LOCK_FILE" 2>/dev/null
fi

# Compute reset & session-usage segments from cached api state
reset_segment=""
session_segment=""
now_epoch=$(date +%s)
if [[ "$RESET_EPOCH" =~ ^[0-9]+$ ]] && [ "$RESET_EPOCH" -gt "$now_epoch" ]; then
  remaining=$(( RESET_EPOCH - now_epoch ))
  hours=$(( remaining / 3600 ))
  minutes=$(( (remaining % 3600) / 60 ))
  if [ "$hours" -gt 0 ]; then
    reset_segment="Resets in ${hours}h ${minutes}m"
  else
    reset_segment="Resets in ${minutes} min"
  fi
fi
if [ -n "$UTILIZATION" ]; then
  # Convert "0.03" -> "3%". Round half-up.
  session_pct=$(awk -v u="$UTILIZATION" 'BEGIN { printf "%.0f", u * 100 }')
  if [[ "$session_pct" =~ ^[0-9]+$ ]]; then
    session_segment="Session ${session_pct}%"
  fi
fi

# Build output: model | dir | context% | session% | reset
sep=" ${DIM}|${RESET} "
printf "${MAGENTA}%s${RESET}" "$model"
printf "${sep}${CYAN}%s${RESET}" "$dir"
[ -n "$context_segment" ] && printf "${sep}%s" "$context_segment"
[ -n "$session_segment" ] && printf "${sep}%s" "$session_segment"
[ -n "$reset_segment" ] && printf "${sep}${YELLOW}%s${RESET}" "$reset_segment"

# --- background refresh of api reset ---
# Refresh when cache is missing, older than 30 min, or already past the cached reset.
cache_age=999999
if [ -s "$API_FILE" ]; then
  cache_age=$(( now_epoch - $(stat -f %m "$API_FILE" 2>/dev/null || echo 0) ))
fi
needs_refresh=0
# Reset epoch only changes at window rollover, but session utilization climbs
# steadily — refresh more often (every 5 min) to keep it usefully current.
[ "$cache_age" -ge 300 ] && needs_refresh=1
[ "$RESET_EPOCH" -le "$now_epoch" ] && needs_refresh=1

if [ "$needs_refresh" = "1" ] && { mkdir "$LOCK_FILE" 2>/dev/null; }; then
  (
    trap 'rmdir "$LOCK_FILE" 2>/dev/null' EXIT
    cred=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || exit 0
    token=$(printf '%s' "$cred" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [ -n "$token" ] || exit 0
    hdr_file=$(mktemp)
    body_file=$(mktemp)
    curl -sS --max-time 15 -D "$hdr_file" -o "$body_file" \
      -X POST https://api.anthropic.com/v1/messages \
      -H "Authorization: Bearer $token" \
      -H "anthropic-version: 2023-06-01" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "Content-Type: application/json" \
      -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}' \
      >/dev/null 2>&1
    epoch=$(grep -i '^anthropic-ratelimit-unified-5h-reset:' "$hdr_file" 2>/dev/null \
      | awk -F': ' '{print $2}' | tr -d '\r\n ')
    util=$(grep -i '^anthropic-ratelimit-unified-5h-utilization:' "$hdr_file" 2>/dev/null \
      | awk -F': ' '{print $2}' | tr -d '\r\n ')
    rm -f "$hdr_file" "$body_file"
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
      {
        printf 'RESET_EPOCH=%s\n' "$epoch"
        [ -n "$util" ] && printf 'UTILIZATION=%s\n' "$util"
      } > "$API_FILE"
    fi
  ) >/dev/null 2>&1 &
  disown 2>/dev/null
fi
