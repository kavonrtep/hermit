#!/usr/bin/env bash
# Claude Code PreToolUse hook — blocks bare conda/pip/mamba install
# Reads JSON from stdin, checks tool_input.command
# Exit 0 = allow, Exit 2 = block

# Read all stdin
input=$(cat)

# Extract the command field using python (always available in container)
cmd=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
print(data.get('tool_input', {}).get('command', ''))
" "$input" 2>/dev/null) || exit 0

# No command = not a Bash call, allow
[[ -z "$cmd" ]] && exit 0

# Check for blocked patterns
# Use here-string to avoid subshell exit code issues
blocked=false
reason=""

while IFS= read -r line; do
    # conda install (but not conda activate, conda create, etc.)
    if [[ "$line" =~ (^|[;|&])[[:space:]]*(conda|mamba)[[:space:]]+install ]]; then
        blocked=true
        reason="bare '$(echo "$line" | grep -oP '(conda|mamba)\s+install')'"
        break
    fi
    # pip install (bare)
    if [[ "$line" =~ (^|[;|&])[[:space:]]*pip3?[[:space:]]+install ]]; then
        blocked=true
        reason="bare 'pip install'"
        break
    fi
done <<< "$cmd"

# Allow mamba create -p (manual isolated env creation)
if [[ "$cmd" =~ mamba[[:space:]]+create[[:space:]].*-p ]]; then
    exit 0
fi

if [[ "$blocked" == true ]]; then
    echo "BLOCKED: ${reason} is not allowed." >&2
    echo "" >&2
    echo "Use 'htool <package>' instead — it searches all environments first," >&2
    echo "then installs to an isolated conda env with proper logging." >&2
    echo "" >&2
    echo "For multi-package environments, use:" >&2
    echo "  mamba create -y -p /envs/conda/envs/NAME -c bioconda -c conda-forge PKG1 PKG2" >&2
    exit 2
fi

exit 0
