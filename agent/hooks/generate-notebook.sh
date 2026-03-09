#!/usr/bin/env bash
# Claude Code Stop hook — generates NOTEBOOK.md from accumulated session data
# Runs when Claude Code session ends

[[ -z "${DATA_OUTPUT_DIR:-}" ]] && exit 0

# Check stop_hook_active to prevent infinite loops
input=$(cat)
is_active=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
print(data.get('stop_hook_active', False))
" "$input" 2>/dev/null) || true

[[ "$is_active" == "True" ]] && exit 0

NOTEBOOK="${DATA_OUTPUT_DIR}/NOTEBOOK.md"
CMD_LOG="${DATA_OUTPUT_DIR}/.command_log"
METHODS="${DATA_OUTPUT_DIR}/METHODS.md"
INSTALL_LOG="/envs/installed.log"

# Skip if no commands were logged (nothing happened)
[[ ! -f "$CMD_LOG" ]] && exit 0

mkdir -p "$(dirname "$NOTEBOOK")"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S")

# Determine session start from first log entry
SESSION_START=$(head -1 "$CMD_LOG" | cut -d'|' -f1)
SESSION_END=$TIMESTAMP
TOTAL_COMMANDS=$(wc -l < "$CMD_LOG")

{
    echo "# Lab Notebook"
    echo ""
    echo "## Session Info"
    echo ""
    echo "| Field | Value |"
    echo "|-------|-------|"
    echo "| Generated | ${TIMESTAMP} |"
    echo "| Session start | ${SESSION_START} |"
    echo "| Session end | ${SESSION_END} |"
    echo "| Total commands | ${TOTAL_COMMANDS} |"
    echo "| CPUs | ${AGENT_CPUS:-unknown} |"
    echo "| Memory | ${AGENT_MEMORY:-unknown} GB |"
    echo ""

    # --- Data paths ---
    echo "## Data Paths"
    echo ""
    echo "| Path | Access |"
    echo "|------|--------|"
    IFS=',' read -ra DIRS <<< "${DATA_INPUT_DIRS:-}"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)
        [[ -n "$dir" ]] && echo "| \`${dir}\` | read-only |"
    done
    echo "| \`${DATA_OUTPUT_DIR}\` | writable (output) |"
    [[ -n "${DATA_REFS_DIR:-}" ]] && echo "| \`${DATA_REFS_DIR}\` | read-only (refs) |"
    echo ""

    # --- Methods (agent reasoning) ---
    if [[ -f "$METHODS" ]]; then
        echo "## Methods"
        echo ""
        # Include METHODS.md content, skip its title line
        tail -n +2 "$METHODS"
        echo ""
    fi

    # --- Command log ---
    echo "## Command Log"
    echo ""
    echo "All commands executed during this session."
    echo ""
    echo '```'
    echo "# timestamp | command"
    while IFS='|' read -r ts cmd; do
        printf "%s | %s\n" "$ts" "$cmd"
    done < "$CMD_LOG"
    echo '```'
    echo ""

    # --- Output files ---
    echo "## Output Files"
    echo ""
    echo '```'
    if [[ -d "$DATA_OUTPUT_DIR" ]]; then
        find "$DATA_OUTPUT_DIR" -maxdepth 2 -type f \
            ! -name ".command_log" \
            -printf "%s\t%p\n" 2>/dev/null | \
        awk '{
            size=$1; path=$2;
            if (size >= 1073741824) printf "%7.1f GB  %s\n", size/1073741824, path;
            else if (size >= 1048576) printf "%7.1f MB  %s\n", size/1048576, path;
            else if (size >= 1024) printf "%7.1f KB  %s\n", size/1024, path;
            else printf "%7d B   %s\n", size, path;
        }' | sort -t'/' -k2
    fi
    echo '```'
    echo ""

    # --- Software versions ---
    echo "## Software Versions"
    echo ""
    echo "### Baked-in"
    echo '```'
    for tool in samtools bcftools bedtools bwa minimap2 python3; do
        if command -v "$tool" &>/dev/null; then
            ver=$("$tool" --version 2>&1 | head -1) || ver="unknown"
            printf "%-15s %s\n" "$tool" "$ver"
        fi
    done
    echo '```'
    echo ""

    if [[ -f "$INSTALL_LOG" ]]; then
        echo "### Runtime-installed"
        echo '```'
        grep "| OK" "$INSTALL_LOG" 2>/dev/null || echo "(none)"
        echo '```'
        echo ""
    fi

    echo "---"
    echo "*Generated automatically by hermit at session end.*"

} > "$NOTEBOOK"

echo "Lab notebook written to ${NOTEBOOK}" >&2

exit 0
