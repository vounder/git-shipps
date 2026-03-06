# git-shipps 🚢

**A lightweight PowerShell deploy script for projects hosted on GitHub and running Docker Compose on a Linux VPS.**

The flow is simple:
1. Commit local changes (with a commit message passed directly as argument)
2. Push to GitHub
3. SSH into the VPS → `git pull`
4. Run `docker compose up -d --build`
5. Optional health check

---

## Requirements

**Local machine (Windows)**
- PowerShell 5.1+
- Git
- SSH client (bundled with Windows 10/11)

**VPS (Linux)**
- Git
- Docker + Docker Compose
- SSH access

---

## Setup (one-time)

### 1. Clone this repo

```powershell
git clone https://github.com/vounder/git-shipps.git
cd git-shipps
```

### 2. Copy the example config

```powershell
cp deploy.config.example.ps1 deploy.config.ps1
```

Edit `deploy.config.ps1` and fill in your values:

```powershell
$SERVER_USER  = "root"
$SERVER_IP    = "1.2.3.4"
$REMOTE_APP   = "/root/myapp"
$COMPOSE_FILE = "docker-compose.prod.yml"
$DEPLOY_KEY   = "$HOME\.ssh\deploy_key"
$HEALTH_URL   = "http://127.0.0.1:3000/health"   # optional
$APP_URL      = "https://example.com"             # optional
$WEBHOOK_URL  = ""                                # optional — Discord/Slack
```

> `deploy.config.ps1` is in `.gitignore` — it will never be committed.

### 3. Run the setup script

This generates an SSH key, copies it to your VPS, and clones your app repo there:

```powershell
.\setup-deploy-key.ps1 -ServerIP 1.2.3.4 -RepoUrl https://github.com/you/myapp
```

**Options:**

| Parameter    | Required | Default                         | Description                          |
|--------------|----------|---------------------------------|--------------------------------------|
| `-ServerIP`  | ✅       | —                               | IP address or hostname of the VPS    |
| `-RepoUrl`   | ✅       | —                               | Full GitHub URL of your app repo     |
| `-ServerUser`| ❌       | `root`                          | SSH user on the VPS                  |
| `-RemoteApp` | ❌       | `/root/<repo-name>` or `/home/<user>/<repo-name>` | Path where the repo will be cloned   |
| `-KeyName`   | ❌       | `deploy_key`                    | Name for the generated SSH key file  |

### 4. Set up your `.env` on the VPS

```bash
ssh -i ~/.ssh/deploy_key root@1.2.3.4
nano /root/myapp/.env
```

### 5. Deploy

```powershell
.\deploy.ps1 "initial deploy"
```

---

## Usage

```powershell
# Deploy with commit message
.\deploy.ps1 "feat: add user profile page"
.\deploy.ps1 "fix: correct payment calculation"

# Deploy to a specific environment (loads deploy.config.staging.ps1)
.\deploy.ps1 "feat: test on staging" -Env staging

# Preview what would happen — no changes made
.\deploy.ps1 -DryRun

# Roll back to the previous deployment
.\deploy.ps1 -Rollback

# Show deployment history (last 20 deploys)
.\deploy.ps1 -History

# Show container status & logs on the VPS
.\deploy.ps1 -Status
```

### What happens during a deploy

```
>> Checking server connection (1.2.3.4)...
   OK: Server reachable

>> Checking local changes...
   M frontend/src/pages/HomePage.tsx
   ?? frontend/src/pages/NewPage.tsx

   Commit message: feat: add new page

   OK: Committed: feat: add new page

>> Pushing to GitHub...
   OK: Pushed: 1 commit(s)

>> VPS: pulling latest changes...
   OK: Code up to date on VPS

>> Building and starting Docker containers...
   OK: Containers started

>> Running health check...
   OK: Health check passed (HTTP 200)

================================================
  Deployment complete!
================================================
  https://example.com

  Useful commands:
  ssh root@1.2.3.4 'docker compose -f /root/myapp/docker-compose.prod.yml logs --tail 50'
  ssh root@1.2.3.4 'docker ps'
  .\deploy.ps1 -Rollback    # revert to previous deploy
  .\deploy.ps1 -History     # show deployment log
  .\deploy.ps1 -Status      # container status on VPS
```

---

## File overview

| File                          | Description                                                   |
|-------------------------------|---------------------------------------------------------------|
| `deploy.ps1`                  | Main deploy script — commit, push, pull, build                |
| `deploy.config.ps1`           | Your config (gitignored, created from example)                |
| `deploy.config.example.ps1`   | Config template to copy and fill in                           |
| `setup-deploy-key.ps1`        | One-time setup: SSH key + VPS clone                           |
| `hooks/pre-deploy.ps1`        | Optional: runs before deploy (tests, linting, etc.)           |
| `hooks/post-deploy.ps1`       | Optional: runs after deploy (cache clear, notifications, etc.)|

---

## Features

### Multi-Environment

Create separate configs for each environment:

```powershell
cp deploy.config.example.ps1 deploy.config.staging.ps1
cp deploy.config.example.ps1 deploy.config.prod.ps1
```

Deploy to a specific environment:

```powershell
.\deploy.ps1 "feat: new feature" -Env staging
.\deploy.ps1 "feat: new feature" -Env prod
```

### Rollback

Before every deploy, git-shipps saves the current commit hash on the VPS as a rollback point. To revert:

```powershell
.\deploy.ps1 -Rollback
```

This checks out the previous commit on the VPS and rebuilds Docker containers.

### Deployment History

Every deploy is logged to `~/.git-shipps/history.log`. View the last 20 entries:

```powershell
.\deploy.ps1 -History
```

Output:
```
  Deployment History (last 20)
  ═══════════════════════════════════════════════════════════
  [v] 2026-03-06 14:22:01   a3f1b2c  feat: add new page  (38s)
  [v] 2026-03-05 09:11:44   d9e8c7f  fix: payment calc  (41s)
  [!] 2026-03-04 18:03:22   b1a2c3d  chore: update deps  (55s)
```

### Dry-Run

Preview exactly what would happen without making any changes:

```powershell
.\deploy.ps1 "feat: test" -DryRun
```

### Status Dashboard

Check container health without SSHing manually:

```powershell
.\deploy.ps1 -Status
```

Shows: running containers, last 20 log lines, disk usage, memory.

### Webhook Notifications

Add a Discord or Slack webhook to `deploy.config.ps1`:

```powershell
$WEBHOOK_URL = "https://discord.com/api/webhooks/..."
```

After each deploy, a message is posted:
```
✅ git-shipps — Deploy to 1.2.3.4
> a3f1b2c feat: add new page
```

### Pre/Post-Deploy Hooks

Create optional hook scripts (not committed, gitignored by pattern):

```
hooks/pre-deploy.ps1   # runs before the VPS pull — exit 1 aborts the deploy
hooks/post-deploy.ps1  # runs after containers are up — failure is logged but non-fatal
```

Example `hooks/pre-deploy.ps1`:
```powershell
# Run tests before deploying
npm test
if ($LASTEXITCODE -ne 0) { exit 1 }
```

### Deploy Lock

git-shipps prevents concurrent deployments by placing a lock file on the VPS. If another deploy is running, the second one fails immediately with a clear message. The lock is automatically released on completion or after 10 minutes (stale lock timeout).

---

## Private GitHub repos

If your app repo is private, you need to add a GitHub deploy key:

1. Grab the public key generated by `setup-deploy-key.ps1`:
   ```powershell
   Get-Content "$HOME\.ssh\deploy_key.pub"
   ```
2. Go to your app repo on GitHub → **Settings → Deploy keys → Add deploy key**
3. Paste the public key (read-only is enough)
4. On the VPS, configure git to use the key:
   ```bash
   git config -C /root/myapp core.sshCommand 'ssh -i ~/.ssh/deploy_key'
   ```

---

## Tips

- **Keep commit messages meaningful** — they show up directly in your git log and make it easy to trace what was deployed when.
- **Health check URL** — point `$HEALTH_URL` to any endpoint in your app that returns HTTP 200 (e.g. `/api/health`, `/ping`).
- **Zero-downtime** — this script uses `docker compose up -d --build` which replaces containers with minimal downtime. For true zero-downtime, consider adding a reverse proxy (nginx/Traefik) in front.
- **Multiple environments** — create `deploy.config.staging.ps1` and `deploy.config.prod.ps1`, then use `.\deploy.ps1 -Env staging`.

---

## AI Agent Integration

git-shipps ships with [`AGENTS.md`](AGENTS.md) — a machine-readable instruction file that AI coding agents (Claude Code, Cursor, Gemini CLI, etc.) pick up **automatically** when they open this directory.

### How it works

| Agent | Discovery mechanism |
|-------|-------------------|
| **Claude Code** (`claude` CLI) | reads `AGENTS.md` + `CLAUDE.md` on startup |
| **Cursor** | reads `AGENTS.md` in project root |
| **Gemini CLI** | reads `AGENTS.md` in project root |
| **GitHub Copilot (chat)** | paste the skill prompt below |
| **Any chat-based AI** | paste the skill prompt below |

### Copyable skill prompt

Use this for ChatGPT, Claude.ai, Copilot Chat, or any AI that doesn't auto-read `AGENTS.md`:

```
Hey! I'm using git-shipps to deploy my project.
Skill reference: https://github.com/vounder/git-shipps — read AGENTS.md for full instructions.

Short summary:
- Deploy:   .\deploy.ps1 "commit message"
- Staging:  .\deploy.ps1 "message" -Env staging
- Dry-run:  .\deploy.ps1 -DryRun
- Rollback: .\deploy.ps1 -Rollback
- Status:   .\deploy.ps1 -Status
- History:  .\deploy.ps1 -History

Config is in deploy.config.ps1 (gitignored). Keys: SERVER_USER, SERVER_IP, REMOTE_APP,
COMPOSE_FILE, DEPLOY_KEY, HEALTH_URL, APP_URL, WEBHOOK_URL, DEFAULT_BRANCH.

Agent guidance: always suggest -DryRun if I seem unsure; suggest -Rollback if health check
fails; ask for a meaningful commit message if I don't provide one.
```

### For Claude Code users

Just `cd` into the project directory — Claude Code reads `AGENTS.md` automatically.
No extra setup needed. Then ask naturally:

```
deploy with "feat: add payment page"
rollback the last deploy
what's running on the server?
dry-run the next deploy
```

---

## License

MIT
