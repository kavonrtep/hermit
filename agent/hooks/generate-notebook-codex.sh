#!/usr/bin/env bash
# Codex CLI session-end notebook generator
# Equivalent of Claude Code's generate-notebook.sh Stop hook,
# adapted for Codex which has no hook system.
#
# Called by codex-wrapper on session exit.
# Usage: generate-notebook-codex.sh <session_start_timestamp>

[[ -z "${DATA_OUTPUT_DIR:-}" ]] && exit 0

SESSION_START="${1:-unknown}"
SESSION_END=$(date -u +"%Y-%m-%dT%H:%M:%S")

NOTEBOOK="${DATA_OUTPUT_DIR}/NOTEBOOK.md"
CMD_LOG="${DATA_OUTPUT_DIR}/.command_log"
METHODS="${DATA_OUTPUT_DIR}/METHODS.md"
INSTALL_LOG="/envs/installed.log"

mkdir -p "$(dirname "$NOTEBOOK")"

{
    echo "# Lab Notebook"
    echo ""
    echo "## Session Info"
    echo ""
    echo "| Field | Value |"
    echo "|-------|-------|"
    echo "| Generated | ${SESSION_END} |"
    echo "| Agent | Codex CLI |"
    echo "| Session start | ${SESSION_START} |"
    echo "| Session end | ${SESSION_END} |"
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
        tail -n +2 "$METHODS"
        echo ""
    fi

    # --- Command log (if available — populated by Claude's hook, may be
    #     partially present if both agents were used in the same output dir) ---
    if [[ -f "$CMD_LOG" ]]; then
        TOTAL_COMMANDS=$(wc -l < "$CMD_LOG")
        echo "## Command Log"
        echo ""
        echo "Commands logged: ${TOTAL_COMMANDS}"
        echo ""
        echo '```'
        echo "# timestamp | command"
        while IFS='|' read -r ts cmd; do
            printf "%s | %s\n" "$ts" "$cmd"
        done < "$CMD_LOG"
        echo '```'
        echo ""
    else
        echo "## Command Log"
        echo ""
        echo "*Command-level logging is not available for Codex CLI sessions.*"
        echo "*Use \`hlog\` during analysis to record key steps in METHODS.md.*"
        echo ""
    fi

    # --- Output files ---
    echo "## Output Files"
    echo ""
    echo '```'
    if [[ -d "$DATA_OUTPUT_DIR" ]]; then
        find "$DATA_OUTPUT_DIR" -maxdepth 2 -type f \
            ! -name ".command_log" \
            ! -name ".session_start" \
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
    echo "*Generated automatically by hermit (Codex CLI session) at session end.*"

} > "$NOTEBOOK"

echo "Lab notebook written to ${NOTEBOOK}" >&2
exit 0
