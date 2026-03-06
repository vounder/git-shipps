# git-shipps — Generic Docker Compose Deploy Script for Windows PowerShell
# https://github.com/vounder/git-shipps
#
# Usage:
#   .\deploy.ps1                        # prompts for commit message
#   .\deploy.ps1 "feat: new feature"   # commit message as argument
#
# Requirements:
#   • deploy.config.ps1 must exist (copy from deploy.config.example.ps1)
#   • Run setup-deploy-key.ps1 once to configure SSH access to your VPS

param(
    [string]$CommitMessage = ""
)

# ── Load config ──────────────────────────────────────────────────────────────
$ConfigFile = Join-Path $PSScriptRoot "deploy.config.ps1"
if (-not (Test-Path $ConfigFile)) {
    Write-Host ""
    Write-Host "  ERROR: deploy.config.ps1 not found." -ForegroundColor Red
    Write-Host "  Copy deploy.config.example.ps1 to deploy.config.ps1 and fill in your values." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
. $ConfigFile

# ── Validate required config values ──────────────────────────────────────────
$missing = @()
if (-not $SERVER_USER)  { $missing += "SERVER_USER" }
if (-not $SERVER_IP)    { $missing += "SERVER_IP" }
if (-not $REMOTE_APP)   { $missing += "REMOTE_APP" }
if (-not $COMPOSE_FILE) { $missing += "COMPOSE_FILE" }
if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "  ERROR: Missing required config values: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "  Check your deploy.config.ps1" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

$SERVER       = "$SERVER_USER@$SERVER_IP"
$PROJECT_ROOT = Get-Location
$BRANCH       = if ($DEFAULT_BRANCH) { $DEFAULT_BRANCH } else { "main" }

# ── Helper functions ──────────────────────────────────────────────────────────
function Step($msg) { Write-Host ""; Write-Host ">> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "   OK: $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "   WARNING: $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "   ERROR: $msg" -ForegroundColor Red; exit 1 }

function RunRemote([string]$Script) {
    # Encodes the script as base64 to safely handle special characters over SSH
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Script -replace "`r`n", "`n"))
    $b64   = [System.Convert]::ToBase64String($bytes)
    $sshArgs = @($SERVER, "echo $b64 | base64 -d | bash")
    if ($DEPLOY_KEY) { $sshArgs = @("-i", $DEPLOY_KEY) + $sshArgs }
    ssh @sshArgs
}

function SshCmd([string]$Cmd) {
    if ($DEPLOY_KEY) {
        ssh -i $DEPLOY_KEY $SERVER $Cmd
    } else {
        ssh $SERVER $Cmd
    }
}

# ── Check SSH connectivity ────────────────────────────────────────────────────
Step "Checking server connection ($SERVER_IP)..."
$sshTestArgs = @("-o", "ConnectTimeout=10", "-o", "BatchMode=yes")
if ($DEPLOY_KEY) { $sshTestArgs += @("-i", $DEPLOY_KEY) }
$sshTestArgs += @($SERVER, "echo OK")
$test = ssh @sshTestArgs 2>&1
if ($test -ne "OK") {
    Fail "SSH connection failed. Check your SERVER_IP, SERVER_USER and DEPLOY_KEY in deploy.config.ps1"
}
Ok "Server reachable"

# ── Check if VPS has a git repo ───────────────────────────────────────────────
$gitCheck = SshCmd "if [ -d $REMOTE_APP/.git ]; then echo YES; else echo NO; fi" 2>$null

if ($gitCheck -ne "YES") {
    Write-Host ""
    Write-Host "  INFO: No git repository found at $REMOTE_APP on the VPS." -ForegroundColor Yellow
    Write-Host "  Run setup-deploy-key.ps1 first to clone your repo on the server:" -ForegroundColor Yellow
    Write-Host "  .\setup-deploy-key.ps1 -ServerIP $SERVER_IP" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

# ── Commit local changes ──────────────────────────────────────────────────────
Step "Checking local changes..."
$dirty = git -C $PROJECT_ROOT status --porcelain 2>$null
if ($dirty) {
    Write-Host ""
    $dirty | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    Write-Host ""
    if ($CommitMessage) {
        $msg = $CommitMessage
        Write-Host "   Commit message: $msg" -ForegroundColor DarkGray
    } else {
        $msg = Read-Host "   Commit message (empty = 'deploy: update')"
        if (-not $msg) { $msg = "deploy: update" }
    }
    git -C $PROJECT_ROOT add -A
    git -C $PROJECT_ROOT commit -m $msg
    if ($LASTEXITCODE -ne 0) { Fail "git commit failed" }
    Ok "Committed: $msg"
} else {
    Ok "No local changes"
}

# ── Push to GitHub ────────────────────────────────────────────────────────────
Step "Pushing to GitHub..."
$unpushed = git -C $PROJECT_ROOT log "origin/$BRANCH..HEAD" --oneline 2>$null
if (-not $unpushed) {
    Ok "Nothing to push (already up to date)"
} else {
    git -C $PROJECT_ROOT push origin $BRANCH
    if ($LASTEXITCODE -ne 0) { Fail "git push failed" }
    Ok "Pushed: $(@($unpushed).Count) commit(s)"
}

# ── VPS: git pull ─────────────────────────────────────────────────────────────
Step "VPS: pulling latest changes..."
RunRemote @"
cd $REMOTE_APP
GIT_SSH_COMMAND='ssh -i ~/.ssh/deploy_key -o StrictHostKeyChecking=no' git pull origin $BRANCH
"@
if ($LASTEXITCODE -ne 0) { Fail "git pull failed on VPS" }
Ok "Code up to date on VPS"

# ── Docker compose up ─────────────────────────────────────────────────────────
Step "Building and starting Docker containers..."
RunRemote @"
cd $REMOTE_APP
docker compose -f $COMPOSE_FILE up -d --build
"@
if ($LASTEXITCODE -ne 0) { Fail "Docker build/start failed" }
Ok "Containers started"

# ── Health check (optional) ───────────────────────────────────────────────────
if ($HEALTH_URL) {
    Step "Running health check..."
    Start-Sleep -Seconds 8
    $health = SshCmd "curl -s -o /dev/null -w '%{http_code}' $HEALTH_URL"
    if (-not $health) { $health = "000" }
    if ($health -eq "200") {
        Ok "Health check passed (HTTP 200)"
    } else {
        Warn "Health check returned HTTP $health (service may still be starting)"
        Write-Host "   Check logs: ssh $SERVER 'docker compose -f $REMOTE_APP/$COMPOSE_FILE logs --tail 50'" -ForegroundColor Yellow
    }
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  Deployment complete!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
if ($APP_URL) {
    Write-Host "  $APP_URL" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor DarkGray
Write-Host "  ssh $SERVER 'docker compose -f $REMOTE_APP/$COMPOSE_FILE logs --tail 50'"
Write-Host "  ssh $SERVER 'docker ps'"
Write-Host ""
