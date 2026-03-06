#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run_agent.sh - Launch AI coding agents in a sandboxed Singularity container
#
# Usage:
#   ./run_agent.sh --setup                        # Install agents
#   ./run_agent.sh --auth claude                  # Authenticate
#   ./run_agent.sh start                          # Start persistent instance
#   ./run_agent.sh stop                           # Stop instance
#   ./run_agent.sh claude                         # Attach Claude Code
#   ./run_agent.sh codex                          # Attach Codex CLI
#   ./run_agent.sh shell                          # Attach bash
#   ./run_agent.sh claude --task "prompt"         # Autonomous task
#   ./run_agent.sh status                         # Show instance status
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_NAME="${INSTANCE_NAME:-hermit}"

# --- Configuration -----------------------------------------------------------
# Load .env FIRST so it can override all defaults below
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"

SIF_IMAGE="${SIF_IMAGE:-${SCRIPT_DIR}/bioinfo-agent.sif}"

# DATA PATHS (external — these vary per server/project):
#   Mounted at their ORIGINAL host paths inside the container (no renaming).
#   INPUT_DIRS: comma-separated list of read-only data directories.
#   OUTPUT_DIR: writable results directory (ideally same drive as input).
INPUT_DIRS="${INPUT_DIRS:-}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
REFS_DIR="${REFS_DIR:-}"

# INTERNAL PATHS (self-contained — travel with the project):
WORKSPACE_DIR="${WORKSPACE_DIR:-${SCRIPT_DIR}/workspace}"
ENVS_DIR="${ENVS_DIR:-${SCRIPT_DIR}/envs}"
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}/config}"

# Credential directories (inside CONFIG_DIR by default)
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${CONFIG_DIR}/claude}"
CODEX_CONFIG_DIR="${CODEX_CONFIG_DIR:-${CONFIG_DIR}/codex}"
OPENAI_CONFIG_DIR="${OPENAI_CONFIG_DIR:-${CONFIG_DIR}/openai}"

# --- End configuration -------------------------------------------------------

print_help() {
    cat <<'EOF'
Usage: run_agent.sh [OPTIONS] <COMMAND> [--task "prompt"]

INSTANCE COMMANDS:
  start             Start a persistent container instance
  stop              Stop the running instance
  status            Show instance status and active screen sessions

AGENT COMMANDS (instance must be running):
  claude            Attach interactive Claude Code session
  codex             Attach interactive Codex CLI session
  shell             Attach plain bash shell

SETUP COMMANDS (no instance needed):
  --setup           First-time setup: install Claude Code and Codex CLI
  --auth AGENT      Authenticate an agent (opens browser)

OPTIONS:
  --task "..."      Run autonomous task (non-interactive)
  --task-id ID      Custom task ID for output directory naming
  --cpus N          Limit CPU cores (default: auto-detect)
  --memory NG       Limit memory in GB (default: auto-detect)
  --no-refs         Skip mounting references
  --dry-run         Show the singularity command without executing
  -h, --help        Show this help

ENVIRONMENT VARIABLES (data paths — set in .env):
  INPUT_DIRS          Comma-separated read-only data dirs    [REQUIRED]
  OUTPUT_DIR          Writable results directory              [REQUIRED]
  REFS_DIR            Reference genomes (read-only)           [optional]

ENVIRONMENT VARIABLES (internal — default to project subdirectories):
  WORKSPACE_DIR       Scratch/temp storage                    [./workspace]
  ENVS_DIR            Persistent software                     [./envs]
  CONFIG_DIR          Agent credentials                       [./config]
  INSTANCE_NAME       Container instance name                 [hermit]

PATH MAPPING:
  All directories are mounted at their ORIGINAL host paths inside the
  container. This means paths in logs, scripts, and output match the host
  exactly. Read-only protection is still kernel-enforced via :ro mounts.

  Example .env:
    INPUT_DIRS=/mnt/ceph/454_data,/mnt/ceph/shared_refs
    OUTPUT_DIR=/mnt/ceph/users/petr/results

  Inside container:
    /mnt/ceph/454_data          ← same path, read-only
    /mnt/ceph/users/petr/results ← same path, writable

MULTI-AGENT WORKFLOW:
  ./run_agent.sh start                    # Start instance
  ./run_agent.sh shell                    # Open bash, use screen inside
    screen -S agent1                      # New screen window
    claude --dangerously-skip-permissions # Run agent
    # Ctrl+A, C → new window
    screen -S agent2                      # Another agent
  ./run_agent.sh claude                   # Or attach directly
  ./run_agent.sh stop                     # When done

EXAMPLES:
  ./run_agent.sh start
  ./run_agent.sh claude
  ./run_agent.sh claude --cpus 4 --memory 32G
  ./run_agent.sh claude --task "Run FastQC on /mnt/ceph/454_data/run01/"
  ./run_agent.sh stop
EOF
}

# --- Parse arguments ---------------------------------------------------------
AGENT=""
MODE=""
TASK_PROMPT=""
TASK_ID=""
MOUNT_REFS=true
DRY_RUN=false
USER_CPUS=""
USER_MEMORY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        start)
            MODE="start"; shift ;;
        stop)
            MODE="stop"; shift ;;
        status)
            MODE="status"; shift ;;
        claude|codex|shell)
            MODE="interactive"; AGENT="$1"; shift ;;
        --setup)
            MODE="setup"; shift ;;
        --auth)
            MODE="auth"; AGENT="$2"; shift 2 ;;
        --task)
            MODE="autonomous"; TASK_PROMPT="$2"; shift 2 ;;
        --task-id)
            TASK_ID="$2"; shift 2 ;;
        --cpus)
            USER_CPUS="$2"; shift 2 ;;
        --memory)
            USER_MEMORY="$2"; shift 2 ;;
        --no-refs)
            MOUNT_REFS=false; shift ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        -h|--help)
            print_help; exit 0 ;;
        *)
            echo "Unknown option: $1"; print_help; exit 1 ;;
    esac
done

[[ -z "$MODE" ]] && { print_help; exit 1; }

# --- Resource detection ------------------------------------------------------
detect_resources() {
    local detected_cpus detected_mem_gb

    detected_cpus=$(nproc 2>/dev/null || echo 8)
    detected_mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 64)

    if [[ -n "$USER_CPUS" ]]; then
        AGENT_CPUS=$((USER_CPUS < detected_cpus ? USER_CPUS : detected_cpus))
    else
        AGENT_CPUS=$detected_cpus
    fi

    if [[ -n "$USER_MEMORY" ]]; then
        local req_mem
        req_mem=$(echo "$USER_MEMORY" | sed 's/[gGbB]*$//')
        AGENT_MEMORY=$((req_mem < detected_mem_gb ? req_mem : detected_mem_gb))
    else
        AGENT_MEMORY=$detected_mem_gb
    fi

    export AGENT_CPUS AGENT_MEMORY
}

# --- Helpers -----------------------------------------------------------------
check_data_paths() {
    if [[ -z "$INPUT_DIRS" ]]; then
        echo "Error: INPUT_DIRS is not set. Configure it in .env or environment."
        echo "  Example: INPUT_DIRS=/mnt/ceph/454_data"
        exit 1
    fi
    if [[ -z "$OUTPUT_DIR" ]]; then
        echo "Error: OUTPUT_DIR is not set. Configure it in .env or environment."
        echo "  Example: OUTPUT_DIR=/mnt/ceph/users/petr/results"
        exit 1
    fi
    # Validate each input dir exists
    IFS=',' read -ra DIRS <<< "$INPUT_DIRS"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)  # trim whitespace
        if [[ ! -d "$dir" ]]; then
            echo "Error: INPUT_DIR does not exist: $dir"
            exit 1
        fi
    done
}

ensure_dirs() {
    mkdir -p "$WORKSPACE_DIR" "$ENVS_DIR" "$CONFIG_DIR"
    mkdir -p "${WORKSPACE_DIR}/.claude"
    mkdir -p "${ENVS_DIR}/conda/envs" "${ENVS_DIR}/conda/pkgs" "${ENVS_DIR}/pip"
    mkdir -p "${ENVS_DIR}/local/bin" "${ENVS_DIR}/local/lib" "${ENVS_DIR}/local/include"
    mkdir -p "${ENVS_DIR}/npm_global"
    mkdir -p "${ENVS_DIR}/screens" && chmod 700 "${ENVS_DIR}/screens"
    mkdir -p "${ENVS_DIR}/home"
    mkdir -p "$CLAUDE_CONFIG_DIR" "$CODEX_CONFIG_DIR" "$OPENAI_CONFIG_DIR"
    [[ -n "$OUTPUT_DIR" ]] && mkdir -p "$OUTPUT_DIR"
}

build_binds() {
    local task_output="${1:-}"
    local fake_home="${ENVS_DIR}/home"
    local binds=""

    # Data mounts — same path inside and outside container
    if [[ -n "$INPUT_DIRS" ]]; then
        IFS=',' read -ra DIRS <<< "$INPUT_DIRS"
        for dir in "${DIRS[@]}"; do
            dir=$(echo "$dir" | xargs)
            [[ -n "$binds" ]] && binds+=","
            binds+="${dir}:${dir}:ro"
        done
    fi

    # Output — same path, writable
    if [[ -n "$task_output" ]]; then
        [[ -n "$binds" ]] && binds+=","
        binds+="${task_output}:${task_output}:rw"
    elif [[ -n "$OUTPUT_DIR" ]]; then
        [[ -n "$binds" ]] && binds+=","
        binds+="${OUTPUT_DIR}:${OUTPUT_DIR}:rw"
    fi

    # Workspace — same path
    [[ -n "$binds" ]] && binds+=","
    binds+="${WORKSPACE_DIR}:${WORKSPACE_DIR}:rw"

    # Persistent software
    binds+=",${ENVS_DIR}:/envs:rw"

    # Reference genomes — same path, read-only
    if [[ "$MOUNT_REFS" == true ]] && [[ -n "${REFS_DIR:-}" ]] && [[ -d "$REFS_DIR" ]]; then
        binds+=",${REFS_DIR}:${REFS_DIR}:ro"
    fi

    # Agent credentials — mounted into the fake home
    binds+=",${CLAUDE_CONFIG_DIR}:${fake_home}/.claude:rw"
    binds+=",${CODEX_CONFIG_DIR}:${fake_home}/.codex:rw"
    binds+=",${OPENAI_CONFIG_DIR}:${fake_home}/.config/openai:rw"

    # Agent context files — auto-mounted into workspace
    [[ -f "${SCRIPT_DIR}/CLAUDE.md" ]] && binds+=",${SCRIPT_DIR}/CLAUDE.md:${WORKSPACE_DIR}/CLAUDE.md:ro"
    [[ -f "${SCRIPT_DIR}/AGENTS.md" ]] && binds+=",${SCRIPT_DIR}/AGENTS.md:${WORKSPACE_DIR}/AGENTS.md:ro"

    # Agent wrapper scripts and hooks
    local agent_dir="${SCRIPT_DIR}/agent"
    if [[ -d "$agent_dir" ]]; then
        binds+=",${agent_dir}/bin:/opt/hermit/bin:ro"
        binds+=",${agent_dir}/hooks:/opt/hermit/hooks:ro"
        [[ -f "${agent_dir}/settings.json" ]] && \
            binds+=",${agent_dir}/settings.json:${WORKSPACE_DIR}/.claude/settings.json:ro"
    fi

    echo "$binds"
}

write_env_file() {
    # Write runtime environment as a simple KEY=VAL file.
    # Used with singularity --env-file for reliable env injection.
    local env_file="${ENVS_DIR}/hermit.env"

    # Write line by line to avoid heredoc expansion issues with set -euo pipefail
    : > "$env_file"
    echo "AGENT_CPUS=${AGENT_CPUS:-8}"                  >> "$env_file"
    echo "AGENT_MEMORY=${AGENT_MEMORY:-64}"              >> "$env_file"
    echo "DATA_INPUT_DIRS=${INPUT_DIRS:-}"               >> "$env_file"
    echo "DATA_OUTPUT_DIR=${OUTPUT_DIR:-}"                >> "$env_file"
    echo "DATA_REFS_DIR=${REFS_DIR:-}"                    >> "$env_file"
    echo "CONDA_ENVS_PATH=/envs/conda/envs"              >> "$env_file"
    echo "CONDA_PKGS_DIRS=/envs/conda/pkgs"              >> "$env_file"
    echo "PIP_TARGET=/envs/pip"                           >> "$env_file"
    echo "PYTHONPATH=/envs/pip"                           >> "$env_file"
    echo "LD_LIBRARY_PATH=/envs/local/lib"                >> "$env_file"
    echo "NPM_CONFIG_PREFIX=/envs/npm_global"             >> "$env_file"
    echo "SCREENDIR=/envs/screens"                         >> "$env_file"
    echo "PATH=/opt/hermit/bin:/envs/npm_global/bin:/envs/local/bin:/opt/node/bin:/opt/envs/biotools/bin:/opt/envs/pydata/bin:/envs/pip/bin:/opt/conda/bin:/usr/local/bin:/usr/bin:/bin" >> "$env_file"
    echo "TERM=${TERM:-xterm-256color}"                   >> "$env_file"
    echo "LANG=C.UTF-8"                                   >> "$env_file"
    echo "LC_ALL=C.UTF-8"                                 >> "$env_file"

    # API keys (only if set)
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && \
        echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "$env_file"
    [[ -n "${OPENAI_API_KEY:-}" ]] && \
        echo "OPENAI_API_KEY=${OPENAI_API_KEY}" >> "$env_file"

    echo "  Env file written: $env_file ($(wc -l < "$env_file") lines)"
}

instance_running() {
    singularity instance list 2>/dev/null | grep -q "$INSTANCE_NAME"
}

run_in_instance() {
    # Execute a command inside the running instance
    "$@"
}

# --- Modes -------------------------------------------------------------------

do_start() {
    if instance_running; then
        echo "Instance '$INSTANCE_NAME' is already running."
        echo "Use './run_agent.sh claude' to attach, or './run_agent.sh stop' first."
        exit 0
    fi
    echo "Preparing to start instance '$INSTANCE_NAME'..."
    check_data_paths
    echo "Data paths validated."
    ensure_dirs
    echo "Required directories ensured."
    detect_resources
    echo "Resources detected: ${AGENT_CPUS} CPUs, ${AGENT_MEMORY} GB RAM."


    local binds
    echo "Building bind mounts..."
    binds=$(build_binds "")
    echo "Writing environment file..."
    write_env_file

    echo "Environment file written to ${ENVS_DIR}/hermit.env"

    local fake_home="${ENVS_DIR}/home"

    echo "=== Starting instance: $INSTANCE_NAME ==="
    echo "Input:      $INPUT_DIRS (READ-ONLY, same paths inside)"
    echo "Output:     $OUTPUT_DIR (same path inside)"
    echo "Workspace:  $(readlink -f "$WORKSPACE_DIR")"
    echo "Software:   $(readlink -f "$ENVS_DIR") → /envs"
    echo "Config:     $(readlink -f "$CONFIG_DIR")"
    [[ "$MOUNT_REFS" == true ]] && [[ -n "${REFS_DIR:-}" ]] && [[ -d "$REFS_DIR" ]] && \
        echo "References: $REFS_DIR (READ-ONLY, same path inside)"
    echo "Resources:  ${AGENT_CPUS} CPUs, ${AGENT_MEMORY} GB RAM"
    echo ""

    local env_file="${ENVS_DIR}/hermit.env"
    local cmd=(singularity instance start
        --cleanenv
        --env-file "$env_file"
        --no-home
        --home "$fake_home"
        --bind "$binds"
        "$SIF_IMAGE" "$INSTANCE_NAME")

    echo "Image:      $SIF_IMAGE"
    echo "Env file:   ${env_file}"
    echo "Bind mounts:"
    IFS=',' read -ra MOUNTS <<< "$binds"
    for m in "${MOUNTS[@]}"; do
        echo "  $m"
    done
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo "DRY RUN:"
        echo "${cmd[@]}"
        return 0
    fi

    echo "Starting singularity instance..."
    if ! "${cmd[@]}" 2>&1; then
        echo ""
        echo "ERROR: Failed to start instance '$INSTANCE_NAME'."
        echo ""
        echo "Troubleshooting:"
        echo "  - Check that the image exists: ls -l $SIF_IMAGE"
        echo "  - Check that all bind paths exist"
        echo "  - Try: singularity instance list"
        echo "  - Try running directly: singularity exec --bind \"$binds\" $SIF_IMAGE echo ok"
        exit 1
    fi

    # Verify instance is actually running
    if ! instance_running; then
        echo ""
        echo "ERROR: Instance started but is not running. It may have exited immediately."
        echo "Try running manually to see the error:"
        echo "  singularity exec --bind \"$binds\" $SIF_IMAGE bash"
        exit 1
    fi

    echo "Instance '$INSTANCE_NAME' started successfully."
    echo ""
    echo "Next steps:"
    echo "  ./run_agent.sh claude          # Attach Claude Code"
    echo "  ./run_agent.sh codex           # Attach Codex CLI"
    echo "  ./run_agent.sh shell           # Attach bash (use screen inside)"
    echo "  ./run_agent.sh stop            # Stop instance"
}

do_stop() {
    if ! instance_running; then
        echo "Instance '$INSTANCE_NAME' is not running."
        exit 0
    fi
    echo "Stopping instance '$INSTANCE_NAME'..."
    singularity instance stop "$INSTANCE_NAME"
    echo "Stopped."
}

do_status() {
    echo "=== Singularity instances ==="
    singularity instance list 2>/dev/null || echo "  (none)"
    echo ""
    if instance_running; then
        echo "=== Screen sessions inside $INSTANCE_NAME ==="
        singularity exec "instance://${INSTANCE_NAME}" screen -ls 2>/dev/null || echo "  (none)"
    fi
}

do_setup() {
    echo "=== First-time setup: Claude Code + Codex CLI ==="
    ensure_dirs
    detect_resources

    local binds="${ENVS_DIR}:/envs:rw"
    local fake_home="${ENVS_DIR}/home"
    write_env_file

    local env_file="${ENVS_DIR}/hermit.env"
    singularity exec \
        --cleanenv \
        --env-file "$env_file" \
        --no-home --home "$fake_home" \
        --bind "$binds" \
        "$SIF_IMAGE" \
        bash -c '
        set -e

        echo "--- Installing Claude Code ---"
        npm install -g @anthropic-ai/claude-code
        echo "Claude Code: $(claude --version 2>/dev/null || echo installed)"

        echo ""
        echo "--- Installing Codex CLI ---"
        npm install -g @openai/codex
        echo "Codex CLI: $(codex --version 2>/dev/null || echo installed)"

        echo ""
        echo "--- Creating persistent directories ---"
        mkdir -p /envs/conda/envs /envs/conda/pkgs /envs/pip /envs/R_libs
        mkdir -p /envs/local/bin /envs/local/lib /envs/local/include

        echo ""
        echo "========================================="
        echo "  Setup complete!"
        echo "  Next steps:"
        echo "    ./run_agent.sh --auth claude"
        echo "    ./run_agent.sh --auth codex"
        echo "========================================="
    '
}

do_auth() {
    echo "=== Authenticating: $AGENT ==="
    echo ""
    echo "This will open a browser on the host for OAuth login."
    echo "Credentials are stored in: $CONFIG_DIR"
    echo ""
    ensure_dirs
    detect_resources

    local binds="${ENVS_DIR}:/envs:rw"
    local fake_home="${ENVS_DIR}/home"
    binds+=",${CLAUDE_CONFIG_DIR}:${fake_home}/.claude:rw"
    binds+=",${CODEX_CONFIG_DIR}:${fake_home}/.codex:rw"
    binds+=",${OPENAI_CONFIG_DIR}:${fake_home}/.config/openai:rw"
    write_env_file
    local env_file="${ENVS_DIR}/hermit.env"

    case $AGENT in
        claude)
            echo "Running: claude login"
            echo "Select 'Claude account with subscription' when prompted."
            echo ""
            singularity exec --cleanenv --env-file "$env_file" --no-home --home "$fake_home" --bind "$binds" "$SIF_IMAGE" claude
            ;;
        codex)
            echo "Running: codex (will prompt for ChatGPT login)"
            echo "Select 'Sign in with ChatGPT' when prompted."
            echo ""
            singularity exec --cleanenv --env-file "$env_file" --no-home --home "$fake_home" --bind "$binds" "$SIF_IMAGE" codex
            ;;
        *)
            echo "Unknown agent: $AGENT (use 'claude' or 'codex')"
            exit 1
            ;;
    esac
}

do_interactive() {
    if ! instance_running; then
        echo "Instance '$INSTANCE_NAME' is not running. Starting it first..."
        do_start
        echo ""
    fi

    # Ensure env file is up to date for exec calls
    detect_resources
    write_env_file
    local env_file="${ENVS_DIR}/hermit.env"

    case ${AGENT:-shell} in
        claude)
            echo "Attaching Claude Code to instance '$INSTANCE_NAME'..."
            echo "=================================================="
            singularity exec --cleanenv --env-file "$env_file" \
                --pwd "${WORKSPACE_DIR}" \
                "instance://${INSTANCE_NAME}" \
                claude --dangerously-skip-permissions
            ;;
        codex)
            echo "Attaching Codex CLI to instance '$INSTANCE_NAME'..."
            echo "=================================================="
            singularity exec --cleanenv --env-file "$env_file" \
                --pwd "${WORKSPACE_DIR}" \
                "instance://${INSTANCE_NAME}" \
                codex --dangerously-bypass-approvals-and-sandbox
            ;;
        shell)
            echo "Attaching bash to instance '$INSTANCE_NAME'..."
            echo "Use 'screen' to manage multiple agents."
            echo "  screen -S myagent          # New screen session"
            echo "  claude --dangerously-skip-permissions"
            echo "  Ctrl+A, D                  # Detach"
            echo "  screen -r myagent          # Reattach"
            echo "=================================================="
            singularity exec --cleanenv --env-file "$env_file" \
                --pwd "${WORKSPACE_DIR}" \
                "instance://${INSTANCE_NAME}" \
                bash
            ;;
    esac
}

do_autonomous() {
    [[ -z "$AGENT" ]] && { echo "Error: specify agent (claude or codex)"; exit 1; }
    [[ -z "$TASK_PROMPT" ]] && { echo "Error: --task requires a prompt"; exit 1; }

    if ! instance_running; then
        echo "Instance '$INSTANCE_NAME' is not running. Starting it first..."
        do_start
        echo ""
    fi

    detect_resources
    write_env_file
    local env_file="${ENVS_DIR}/hermit.env"

    # Create task-specific output directory
    [[ -z "$TASK_ID" ]] && TASK_ID="task_$(date +%Y%m%d_%H%M%S)_${AGENT}"
    TASK_OUTPUT_DIR="${OUTPUT_DIR}/${TASK_ID}"
    mkdir -p "$TASK_OUTPUT_DIR"

    LOG_FILE="${TASK_OUTPUT_DIR}/session.log"

    echo "=== Autonomous task: $TASK_ID ==="
    echo "Agent:     $AGENT"
    echo "Prompt:    $TASK_PROMPT"
    echo "Output:    $TASK_OUTPUT_DIR"
    echo "Resources: ${AGENT_CPUS} CPUs, ${AGENT_MEMORY} GB RAM"
    echo "Log:       $LOG_FILE"
    echo ""

    FULL_PROMPT="$(agent_context)

TASK:
${TASK_PROMPT}"

    case $AGENT in
        claude)
            singularity exec --cleanenv --env-file "$env_file" \
                --pwd "${WORKSPACE_DIR}" \
                "instance://${INSTANCE_NAME}" \
                claude --dangerously-skip-permissions \
                -p "$(printf '%s' "$FULL_PROMPT")" \
                2>&1 | tee "$LOG_FILE"
            ;;
        codex)
            singularity exec --cleanenv --env-file "$env_file" \
                --pwd "${WORKSPACE_DIR}" \
                "instance://${INSTANCE_NAME}" \
                codex --dangerously-bypass-approvals-and-sandbox \
                --quiet "$(printf '%s' "$FULL_PROMPT")" \
                2>&1 | tee "$LOG_FILE"
            ;;
        *)
            echo "Unknown agent: $AGENT"; exit 1 ;;
    esac

    echo ""
    echo "=== Task $TASK_ID complete ==="
    echo "Results: $TASK_OUTPUT_DIR"
    [[ -f "${TASK_OUTPUT_DIR}/SUMMARY.md" ]] && {
        echo ""
        echo "--- Summary ---"
        cat "${TASK_OUTPUT_DIR}/SUMMARY.md"
    }
}

# Context prompt for autonomous tasks
agent_context() {
    cat <<CONTEXT
You are running inside a sandboxed Singularity container as a bioinformatics data analyst.

RESOURCE BUDGET:
  CPUs:   ${AGENT_CPUS}
  Memory: ${AGENT_MEMORY} GB
  Leave 1 CPU and ~25% memory for the system.

DATA PATHS (same as host — logs and scripts are portable):
  Input (READ-ONLY):  ${INPUT_DIRS}
  Output (writable):  ${OUTPUT_DIR}
  References (ro):    ${REFS_DIR:-not mounted}
  Workspace:          ${WORKSPACE_DIR}

I/O STRATEGY:
  Input and output are on the same physical drive — avoid unnecessary copies.
  Use ${WORKSPACE_DIR} ONLY for temporary intermediates (sorting, scratch).
  Write final results directly to ${OUTPUT_DIR}.

SOFTWARE:
  Baked-in: samtools, bcftools, bedtools, bwa, minimap2, fastqc, multiqc, trimmomatic
  Python:   pandas, numpy, scipy, scikit-learn, matplotlib, seaborn, pysam, cyvcf2
  Run 'henv' for full inventory with versions.

  To find or install a tool:  htool <name>
  To log an analysis step:    hlog "description" "command"
  To list environments:       henv
  To generate summary:        hsummary

  Do NOT use bare conda/pip/mamba install — use htool instead.
  Exception: mamba create -p /envs/conda/envs/NAME for multi-package envs.

RULES:
  1. NEVER write to input or reference directories (kernel-enforced read-only)
  2. All final results go to ${OUTPUT_DIR}
  3. Clean up ${WORKSPACE_DIR} when done
  4. Write ${OUTPUT_DIR}/SUMMARY.md when finished
CONTEXT
}

# --- Main --------------------------------------------------------------------
case $MODE in
    start)       do_start ;;
    stop)        do_stop ;;
    status)      do_status ;;
    setup)       do_setup ;;
    auth)        do_auth ;;
    interactive) do_interactive ;;
    autonomous)  do_autonomous ;;
esac
