# git-shipps — Agent Instructions

> **Auto-discovery**: This file is read automatically by Claude Code, Cursor, Gemini CLI,
> and most other AI coding agents when the project directory is opened.
> For chat-only sessions, see the [copyable skill prompt](#copyable-skill-prompt) in the README.

git-shipps is a **PowerShell deploy tool** (Windows) that:
1. Commits local changes with a message
2. Pushes to GitHub
3. SSHes into a Linux VPS → `git pull`
4. Runs `docker compose up -d --build`
5. Optionally verifies a health-check URL

---

## When to activate this tool

Trigger git-shipps automatically when the user says anything like:

| Intent | Example phrases |
|--------|----------------|
| Deploy | "deploy", "ship it", "push to prod", "deploy to staging", "release" |
| Rollback | "rollback", "revert", "undo last deploy", "something broke after deploy" |
| Status | "what's running", "check the server", "show logs", "is the app up" |
| History | "when was this deployed", "last deploy", "deployment log" |
| Preview | "what would deploy do", "dry run", "preview deploy" |

---

## Commands

Run all commands from the directory where `deploy.config.ps1` lives.

```powershell
# ── Core deploy ──────────────────────────────────────────────────────────────
.\deploy.ps1 "feat: describe the change"   # commit + push + pull + docker up
.\deploy.ps1                               # same, but prompts for commit message

# ── Environments ─────────────────────────────────────────────────────────────
.\deploy.ps1 "message" -Env staging        # uses deploy.config.staging.ps1
.\deploy.ps1 "message" -Env prod           # uses deploy.config.prod.ps1

# ── Safety ───────────────────────────────────────────────────────────────────
.\deploy.ps1 -DryRun                       # preview only — zero side effects
.\deploy.ps1 -Rollback                     # revert VPS to commit before last deploy

# ── Observability ────────────────────────────────────────────────────────────
.\deploy.ps1 -History                      # last 20 deploys with status + duration
.\deploy.ps1 -Status                       # container status, logs, disk, memory on VPS
```

---

## Configuration

config file: `deploy.config.ps1` (gitignored — never committed)

```powershell
$SERVER_USER    = "root"
$SERVER_IP      = "1.2.3.4"
$REMOTE_APP     = "/root/myapp"
$COMPOSE_FILE   = "docker-compose.prod.yml"
$DEPLOY_KEY     = "$HOME\.ssh\deploy_key"
$HEALTH_URL     = "http://127.0.0.1:3000/health"  # optional
$APP_URL        = "https://example.com"            # optional
$WEBHOOK_URL    = ""                               # optional — Discord/Slack webhook
$DEFAULT_BRANCH = "main"
```

Config does **not exist yet**? → `cp deploy.config.example.ps1 deploy.config.ps1`

---

## One-time VPS setup

```powershell
.\setup-deploy-key.ps1 -ServerIP 1.2.3.4 -RepoUrl https://github.com/you/myapp
```

This generates an SSH key, copies it to the VPS, and clones the repo there.

---

## Decision guide for agents

| Situation | Recommended action |
|-----------|--------------------|
| User unsure / first deploy | Run `-DryRun` first, show output, ask to confirm |
| No commit message given | Ask for a **descriptive** message (conventional commits preferred) |
| Health check fails after deploy | Suggest `.\deploy.ps1 -Rollback` immediately |
| Deploy fails, unclear why | Run `.\deploy.ps1 -Status` to surface container logs |
| Multiple environments in project | Confirm target env explicitly before deploying |
| `deploy.config.ps1` not found | Guide user through `cp deploy.config.example.ps1 deploy.config.ps1` + fill in values |
| Concurrent deploy error | Inform user another deploy is running; wait or remove VPS lock file manually |

---

## Hooks (optional extension points)

Place these files next to `deploy.ps1` — they are auto-executed if they exist:

```
hooks/pre-deploy.ps1    # runs before VPS pull — exit 1 aborts the entire deploy
hooks/post-deploy.ps1   # runs after containers are up — failure is logged, non-fatal
```

---

## Output patterns (for parsing agent output)

| Pattern | Meaning |
|---------|---------|
| `OK: ...` (green) | Step succeeded |
| `WARNING: ...` (yellow) | Non-fatal issue (e.g. health check not 200) |
| `ERROR: ...` (red) + exit | Fatal failure — check the message |
| `[DRY-RUN] ...` (yellow) | Dry-run preview line — no action taken |
| `Deployment complete!` | Full success |
| `Rollback complete!` | Rollback successful |

---

## Repository layout

```
deploy.ps1                  ← main script (run this)
deploy.config.ps1           ← your config (gitignored)
deploy.config.example.ps1   ← config template
setup-deploy-key.ps1        ← one-time VPS setup
hooks/pre-deploy.ps1        ← optional pre-hook (create if needed)
hooks/post-deploy.ps1       ← optional post-hook (create if needed)
AGENTS.md                   ← this file
```
