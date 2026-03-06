# Hermit: Sandboxed AI Data Analyst for Bioinformatics

Run **Claude Code** or **OpenAI Codex CLI** inside a Singularity/Apptainer
container with read-only data protection, resource-aware execution, and
persistent software environments.

## Why This Exists

AI coding agents with full autonomy (`--dangerously-skip-permissions` / `--yolo`)
can accidentally destroy data. This setup uses Singularity bind mounts to
enforce read-only access at the kernel level — no amount of agent confusion
can delete or modify your input data.

The agent acts as a **data analyst**, not a pipeline runner. It explores your
data, picks appropriate tools, and builds custom analyses on the fly.

## Project Layout

Self-contained — copy the whole directory to deploy on a new server.

```
hermit/
├── bioinfo-agent.def        Singularity image definition
├── bioinfo-agent.sif        Built container image
├── run_agent.sh             Launcher script
├── .env                     Configuration (data paths, API keys)
├── CLAUDE.md                Context file for Claude Code
├── AGENTS.md                Context file for Codex CLI
├── config/                  Agent credentials (auto-created)
├── envs/                    Installed software (auto-created)
└── workspace/               Scratch files (can be symlink → SSD)
```

## Quick Start

### 1. Build the image

```bash
sudo singularity build bioinfo-agent.sif bioinfo-agent.def
```

### 2. Configure data paths

```bash
cp env.template .env
vim .env
```

Set your data paths. They are mounted at their **original host locations**
inside the container — paths in logs, scripts, and output match exactly.

```bash
# .env
INPUT_DIRS=/mnt/ceph/454_data,/mnt/ceph/shared_data
OUTPUT_DIR=/mnt/ceph/users/petr/results
REFS_DIR=/mnt/ceph/references
```

**Tip:** Symlink workspace to local SSD for fast temp I/O:
```bash
ln -sfn /local/ssd/scratch ./workspace
```

### 3. Install agents

```bash
chmod +x run_agent.sh
./run_agent.sh --setup
```

### 4. Authenticate

```bash
./run_agent.sh --auth claude    # Claude Code
./run_agent.sh --auth codex     # Codex CLI
```

Credentials are stored in `./config/` and travel with the project.

### 5. Run

```bash
# Start the persistent container instance
./run_agent.sh start

# Attach agents (each in a separate terminal)
./run_agent.sh claude
./run_agent.sh codex
./run_agent.sh shell       # bash with screen for multi-agent

# Autonomous tasks
./run_agent.sh claude --task "Run FastQC on /mnt/ceph/454_data/run01/*.fastq.gz"

# Stop when done
./run_agent.sh stop
```

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Singularity Image (rebuilt rarely)                 │
│  ┌───────────────────────────────────────────┐      │
│  │ Mambaforge base + system packages         │      │
│  │ Node.js 22 + build-essential + dev libs   │      │
│  ├───────────────────────────────────────────┤      │
│  │ /opt/envs/biotools                        │      │
│  │   samtools, bcftools, bedtools, bwa, ...  │      │
│  ├───────────────────────────────────────────┤      │
│  │ /opt/envs/pydata                          │      │
│  │   pandas, numpy, scipy, pysam, cyvcf2 ... │      │
│  └───────────────────────────────────────────┘      │
└──────────────┬──────────────────────────────────────┘
               │ bind mounts (same paths as host)
               │
  /mnt/ceph/454_data:ro      ← input (read-only)
  /mnt/ceph/users/petr:rw    ← output (writable)
  /mnt/ceph/references:ro    ← references (read-only)
  ./workspace:rw              ← local SSD scratch
  ./envs:/envs:rw             ← runtime software
```

### Path Mapping

All data directories are mounted at their **original host paths**. No
`/input`→`/output` translation. Paths in logs, scripts, and agent output
are directly usable on the host.

### Persistent Instance + Screen

```bash
./run_agent.sh start          # Start container instance
./run_agent.sh shell          # Attach bash
  screen -S analyst1          # New screen session
  claude --dangerously-skip-permissions
  # Ctrl+A, D to detach
  screen -S analyst2          # Another agent in parallel
  codex --dangerously-bypass-approvals-and-sandbox
  # Ctrl+A, D to detach
  screen -r analyst1          # Reattach
./run_agent.sh stop           # Stop when done
```

### Software Layers

| Layer | Location | Persistence | Examples |
|-------|----------|-------------|----------|
| **biotools** (baked) | `/opt/envs/biotools` | Immutable | samtools, bwa, bcftools |
| **pydata** (baked) | `/opt/envs/pydata` | Immutable | pandas, pysam, matplotlib |
| Runtime conda envs | `/envs/conda/envs/` | Persistent | rstats, custom envs |
| Pip packages | `/envs/pip` | Persistent | any pip package |
| Compiled tools | `/envs/local` | Persistent | source builds |
| AI agents | npm global | Persistent | claude-code, codex |

---

## Authentication

| Auth mode      | Claude Code               | Codex CLI                    |
|----------------|---------------------------|------------------------------|
| Subscription   | Pro/Max plan ($20-200/mo) | ChatGPT Plus/Pro/Team        |
| API key        | ANTHROPIC_API_KEY         | OPENAI_API_KEY               |

Credentials stored in `./config/`. For headless servers, use API keys in `.env`.

---

## Usage Examples

### Interactive exploration

```bash
./run_agent.sh start
./run_agent.sh claude

You: List all files in /mnt/ceph/454_data and categorize them
You: Run samtools flagstat on each BAM and summarize
You: Sample_03 has low mapping rate. Investigate and save to /mnt/ceph/users/petr/results/
```

### Autonomous tasks

```bash
./run_agent.sh claude --task "
  Find all .fastq.gz in /mnt/ceph/454_data/experiment_42/.
  Run FastQC + MultiQC. Flag samples with >30% bases below Q20.
  Save to /mnt/ceph/users/petr/results.
"
```

### Multiple agents in parallel

```bash
./run_agent.sh start
./run_agent.sh shell
# Inside:
screen -S qc
claude --dangerously-skip-permissions
# "Run QC on batch A"
# Ctrl+A, D

screen -S variants
claude --dangerously-skip-permissions
# "Call variants on batch B"
# Ctrl+A, D

screen -ls                    # List sessions
screen -r qc                  # Reattach
```

---

## Deploying to a New Server

```bash
rsync -av hermit/ newserver:hermit/
ssh newserver
cd hermit
vim .env                      # Update data paths only
ln -sfn /local/ssd/scratch ./workspace   # Optional
./run_agent.sh start && ./run_agent.sh claude
```

Different architecture? Rebuild the image:
```bash
sudo singularity build bioinfo-agent.sif bioinfo-agent.def
```

## Maintenance

```bash
./run_agent.sh shell
npm update -g @anthropic-ai/claude-code
npm update -g @openai/codex

# Rebuild image (rare)
sudo singularity build --force bioinfo-agent.sif bioinfo-agent.def
```

---

## Security Model

1. **`:ro` mounts are kernel-enforced** — even root cannot write
2. **Singularity runs as your user** — no privilege escalation
3. **`--no-home`** — host home directory is not visible
4. **Network is shared** — agents can reach APIs and package repos

This protects against a **confused AI agent**, not a malicious attacker.
