# Additional agent CLIs

Status: implemented

## Problem

Hermit currently installs and launches Claude Code and Codex only. Users who
have GitHub Copilot or Google Antigravity access cannot use those command-line
clients in the same sandbox.

## Interface

`./run_agent.sh --setup` installs `copilot` and `agy` alongside the existing
agents. The commands below run the CLIs in the persistent container instance:

```
./run_agent.sh --auth copilot
./run_agent.sh copilot
./run_agent.sh --auth antigravity
./run_agent.sh antigravity
```

`--auth copilot` runs `copilot login`. `--auth antigravity` starts `agy`,
which presents its SSH-compatible sign-in flow.

## Persistence

Copilot configuration is mounted at `/envs/home/.copilot` from
`config/copilot`. Antigravity configuration is mounted at
`/envs/home/.gemini` from `config/antigravity`. The Antigravity executable is
installed by its official installer and linked into `/envs/local/bin`.

## Failure modes

Setup fails if either vendor installer cannot be downloaded or its command
cannot run. Authentication requires an active Copilot subscription or an
authorised Google account. The login command prints the URL or device code for
headless use.

## Validation

Shell syntax is checked with `bash -n`. Help output is checked for both new
commands. A real installation is performed by the user with `--setup`, because
it downloads vendor-managed binaries.
