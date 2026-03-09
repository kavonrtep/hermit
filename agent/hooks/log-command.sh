#!/usr/bin/env bash
# Claude Code PostToolUse hook for Bash — logs every command to the command log
# Reads JSON on stdin with tool_input.command
# Always exits 0 (never blocks)

# Skip if no output dir
[[ -z "${DATA_OUTPUT_DIR:-}" ]] && exit 0

LOG_FILE="${DATA_OUTPUT_DIR}/.command_log"
input=$(cat)

# Extract command from hook input
cmd=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
cmd = data.get('tool_input', {}).get('command', '')
# Collapse newlines for single-line log entry
print(cmd.replace('\n', ' ; ').strip())
" "$input" 2>/dev/null) || exit 0

[[ -z "$cmd" ]] && exit 0

ts=$(date -u +"%Y-%m-%dT%H:%M:%S")
echo "${ts}|${cmd}" >> "$LOG_FILE"

exit 0
