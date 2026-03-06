# git-shipps — Generic Docker Compose Deploy Script for Windows PowerShell
# https://github.com/vounder/git-shipps
#
# Usage:
#   .\deploy.ps1                              # prompts for commit message
#   .\deploy.ps1 "feat: new feature"         # commit message as argument
#   .\deploy.ps1 -Env staging                # deploy to staging environment
#   .\deploy.ps1 -DryRun                     # preview without deploying
#   .\deploy.ps1 -Rollback                   # roll back to previous deploy
#   .\deploy.ps1 -History                    # show last 20 deployments
#   .\deploy.ps1 -Status                     # show container status on VPS
#
# Requirements:
#   • deploy.config.ps1 must exist (copy from deploy.config.example.ps1)
#   • Run setup-deploy-key.ps1 once to configure SSH access to your VPS

param(
    [string]$CommitMessage = "",
    [string]$Env           = "",       # E3: load deploy.config.<Env>.ps1 instead
    [switch]$DryRun,                   # E5: preview mode — no actual changes
    [switch]$Rollback,                 # E1: roll back to previous deploy
    [switch]$History,                  # E2: show deployment history
    [switch]$Status                    # E7: show container status on VPS
)

# ── Load config ──────────────────────────────────────────────────────────────
$ConfigName = if ($Env) { "deploy.config.$Env.ps1" } else { "deploy.config.ps1" }
$ConfigFile = Join-Path $PSScriptRoot $ConfigName
if (-not (Test-Path $ConfigFile)) {
    Write-Host ""
    Write-Host "  ERROR: $ConfigName not found." -ForegroundColor Red
    if ($Env) {
        Write-Host "  Create deploy.config.$Env.ps1 for the '$Env' environment." -ForegroundColor Yellow
    } else {
        Write-Host "  Copy deploy.config.example.ps1 to deploy.config.ps1 and fill in your values." -ForegroundColor Yellow
    }
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
    Write-Host "  Check your $ConfigName" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# ── S5: Validate config values to prevent command injection ───────────────────────
# All these values are interpolated into remote bash scripts via SSH
if ($SERVER_IP -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,253}$') {
    Write-Host "  ERROR: Invalid SERVER_IP in config: '$SERVER_IP'" -ForegroundColor Red; exit 1
}
if ($SERVER_USER -notmatch '^[a-zA-Z0-9_.-]+$') {
    Write-Host "  ERROR: Invalid SERVER_USER in config: '$SERVER_USER'" -ForegroundColor Red; exit 1
}
if ($REMOTE_APP -notmatch '^[a-zA-Z0-9/_.-]+$') {
    Write-Host "  ERROR: Invalid REMOTE_APP in config: '$REMOTE_APP'" -ForegroundColor Red; exit 1
}
if ($COMPOSE_FILE -notmatch '^[a-zA-Z0-9/_.-]+$') {
    Write-Host "  ERROR: Invalid COMPOSE_FILE in config: '$COMPOSE_FILE'" -ForegroundColor Red; exit 1
}
# S3: Validate HEALTH_URL — must start with http:// or https://, no shell metacharacters
if ($HEALTH_URL -and $HEALTH_URL -notmatch '^https?://[a-zA-Z0-9._/:?=&%-]+$') {
    Write-Host "  ERROR: Invalid HEALTH_URL in config: '$HEALTH_URL'" -ForegroundColor Red
    Write-Host "  Must be a plain http:// or https:// URL without shell metacharacters." -ForegroundColor Yellow
    exit 1
}

$SERVER       = "$SERVER_USER@$SERVER_IP"
$PROJECT_ROOT = Get-Location
$BRANCH       = if ($DEFAULT_BRANCH) { $DEFAULT_BRANCH } else { "main" }

# ── E2: Deployment log setup ───────────────────────────────────────────────
function WriteLog([string]$Status, [string]$CommitMsg, [string]$CommitHash, [int]$DurationSec) {
    $LogDir  = Join-Path $HOME ".git-shipps"
    $LogFile = Join-Path $LogDir "history.log"
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $entry = [PSCustomObject]@{
        timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        server      = $SERVER_IP
        remote_app  = $REMOTE_APP
        branch      = $BRANCH
        env         = if ($Env) { $Env } else { "default" }
        commit_hash = $CommitHash
        commit_msg  = $CommitMsg
        status      = $Status
        duration_s  = $DurationSec
    }
    $entry | ConvertTo-Json -Compress | Add-Content -Path $LogFile -Encoding UTF8
}

# ── E2: History command ───────────────────────────────────────────────────
if ($History) {
    $LogFile = Join-Path $HOME ".git-shipps\history.log"
    if (-not (Test-Path $LogFile)) {
        Write-Host "  No deployment history found." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
    Write-Host "  Deployment History (last 20)" -ForegroundColor Cyan
    Write-Host "  ═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Get-Content $LogFile | Select-Object -Last 20 | ForEach-Object {
        $e = $_ | ConvertFrom-Json
        $icon  = if ($e.status -eq "success") { "v" } else { "!" }
        $color = if ($e.status -eq "success") { "Green" } elseif ($e.status -eq "warning") { "Yellow" } else { "Red" }
        $envLabel = if ($e.env -ne "default") { " [$($e.env)]" } else { "" }
        $shortHash = $e.commit_hash.Substring(0, [Math]::Min(7, $e.commit_hash.Length))
        Write-Host ("  [{0}] {1}{2}  {3}  {4}  ({5}s)" -f $icon, $e.timestamp, $envLabel, $shortHash, $e.commit_msg, $e.duration_s) -ForegroundColor $color
    }
    Write-Host ""
    exit 0
}

# ── Helper functions ─────────────────────────────────────────────────────────
function Step($msg) { Write-Host ""; Write-Host ">> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "   OK: $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "   WARNING: $msg" -ForegroundColor Yellow }
function DryRun($msg) { Write-Host "   [DRY-RUN] $msg" -ForegroundColor DarkYellow }
function Fail($msg, [string]$CommitMsg = "", [string]$Hash = "", [int]$Elapsed = 0) {
    Write-Host "   ERROR: $msg" -ForegroundColor Red
    if ($CommitMsg) { WriteLog "failed" $CommitMsg $Hash $Elapsed }
    exit 1
}

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

# ── E8: Deploy Lock ───────────────────────────────────────────────────────────
$LOCK_FILE    = "/tmp/git-shipps-$($REMOTE_APP -replace '[^a-zA-Z0-9]', '-').lock"
$LOCK_TIMEOUT = 600  # 10 minutes

function AcquireLock {
    $lockScript = @"
LOCK="$LOCK_FILE"
NOW=`$(date +%s)
TIMEOUT=$LOCK_TIMEOUT
if [ -f "`$LOCK" ]; then
    LOCK_TIME=`$(cat "`$LOCK" 2>/dev/null || echo 0)
    AGE=`$(( NOW - LOCK_TIME ))
    if [ "`$AGE" -lt "`$TIMEOUT" ]; then
        echo "LOCKED:`$AGE"
        exit 0
    fi
fi
echo "`$NOW" > "`$LOCK"
echo "ACQUIRED"
"@
    RunRemote $lockScript
}

function ReleaseLock {
    RunRemote "rm -f $LOCK_FILE" | Out-Null
}

# ── E7: Status command ────────────────────────────────────────────────────────
if ($Status) {
    Step "Container status on $SERVER_IP..."
    RunRemote @"
echo ""
echo "=== Running containers ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Docker not accessible"
echo ""
echo "=== App containers (last 20 log lines) ==="
cd $REMOTE_APP 2>/dev/null && docker compose -f $COMPOSE_FILE logs --tail 20 2>/dev/null || echo "No compose logs available"
echo ""
echo "=== Disk ==="
df -h / 2>/dev/null | tail -1
echo ""
echo "=== Memory ==="
free -h 2>/dev/null | grep Mem
"@
    exit 0
}

# ── Check SSH connectivity ────────────────────────────────────────────────────
Step "Checking server connection ($SERVER_IP)..."
if ($DryRun) {
    DryRun "Would SSH to $SERVER"
} else {
    # S4: accept-new accepts unknown hosts on first connect, but warns/blocks if
    #     the host key later changes — prevents Man-in-the-Middle attacks
    $sshTestArgs = @("-o", "ConnectTimeout=10", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new")
    if ($DEPLOY_KEY) { $sshTestArgs += @("-i", $DEPLOY_KEY) }
    $sshTestArgs += @($SERVER, "echo OK")
    $test = ssh @sshTestArgs 2>&1
    if ($test -ne "OK") {
        Fail "SSH connection failed. Check your SERVER_IP, SERVER_USER and DEPLOY_KEY in $ConfigName"
    }
    Ok "Server reachable"
}

# ── Check if VPS has a git repo ───────────────────────────────────────────────
if (-not $DryRun) {
    $gitCheck = SshCmd "if [ -d $REMOTE_APP/.git ]; then echo YES; else echo NO; fi" 2>$null
    if ($gitCheck -ne "YES") {
        Write-Host ""
        Write-Host "  INFO: No git repository found at $REMOTE_APP on the VPS." -ForegroundColor Yellow
        Write-Host "  Run setup-deploy-key.ps1 first to clone your repo on the server:" -ForegroundColor Yellow
        Write-Host "  .\setup-deploy-key.ps1 -ServerIP $SERVER_IP" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }
}

# ── E1: Rollback ──────────────────────────────────────────────────────────────
if ($Rollback) {
    Step "Rolling back previous deployment on $SERVER_IP..."
    $rollbackResult = RunRemote @"
ROLLBACK_FILE="$REMOTE_APP/.git-shipps-last-deploy"
if [ ! -f "\$ROLLBACK_FILE" ]; then
    echo "NO_ROLLBACK_FILE"
    exit 1
fi
PREV_HASH=\$(cat "\$ROLLBACK_FILE")
CURRENT_HASH=\$(cd "$REMOTE_APP" && git rev-parse HEAD)
echo "Current:   \$CURRENT_HASH"
echo "Restoring: \$PREV_HASH"
cd "$REMOTE_APP"
git checkout "\$PREV_HASH"
echo "\$CURRENT_HASH" > "\$ROLLBACK_FILE"
"@
    if ($rollbackResult -match "NO_ROLLBACK_FILE") {
        Fail "No rollback point found. Deploy at least once before using -Rollback."
    }
    if ($LASTEXITCODE -ne 0) { Fail "Rollback: git checkout failed on VPS" }
    $rollbackResult | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    Ok "Code rolled back on VPS"

    Step "Rebuilding Docker containers after rollback..."
    RunRemote @"
cd $REMOTE_APP
docker compose -f $COMPOSE_FILE up -d --build
"@
    if ($LASTEXITCODE -ne 0) { Fail "Docker rebuild failed after rollback" }
    Ok "Containers restarted with previous version"

    Write-Host ""
    Write-Host "================================================" -ForegroundColor Yellow
    Write-Host "  Rollback complete!" -ForegroundColor Yellow
    Write-Host "================================================" -ForegroundColor Yellow
    if ($APP_URL) { Write-Host "  $APP_URL" -ForegroundColor Cyan }
    Write-Host ""
    exit 0
}

# ── E8: Acquire deploy lock ───────────────────────────────────────────────────
if (-not $DryRun) {
    $lockResult = AcquireLock
    if ($lockResult -match "^LOCKED:(\d+)") {
        $age = [int]$Matches[1]
        Fail "Another deployment is in progress (started ${age}s ago). Wait or remove $LOCK_FILE on the VPS manually."
    }
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { ReleaseLock }
}

$DeployStart = Get-Date

# ── Commit local changes ──────────────────────────────────────────────────────
Step "Checking local changes..."
$dirty      = git -C $PROJECT_ROOT status --porcelain 2>$null
$commitHash = ""
$finalMsg   = $CommitMessage

if ($dirty) {
    Write-Host ""
    $dirty | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    Write-Host ""
    if ($CommitMessage) {
        $finalMsg = $CommitMessage
        Write-Host "   Commit message: $finalMsg" -ForegroundColor DarkGray
    } else {
        $finalMsg = Read-Host "   Commit message (empty = 'deploy: update')"
        if (-not $finalMsg) { $finalMsg = "deploy: update" }
    }
    if ($DryRun) {
        DryRun "Would commit: $finalMsg"
    } else {
        git -C $PROJECT_ROOT add -A
        git -C $PROJECT_ROOT commit -m $finalMsg
        if ($LASTEXITCODE -ne 0) { ReleaseLock; Fail "git commit failed" }
        Ok "Committed: $finalMsg"
    }
} else {
    Ok "No local changes"
}

# ── Push to GitHub ────────────────────────────────────────────────────────────
Step "Pushing to GitHub..."
$unpushed = git -C $PROJECT_ROOT log "origin/$BRANCH..HEAD" --oneline 2>$null
if (-not $unpushed) {
    Ok "Nothing to push (already up to date)"
} else {
    if ($DryRun) {
        DryRun "Would push $(@($unpushed).Count) commit(s) to origin/$BRANCH"
    } else {
        git -C $PROJECT_ROOT push origin $BRANCH
        if ($LASTEXITCODE -ne 0) { ReleaseLock; Fail "git push failed" }
        Ok "Pushed: $(@($unpushed).Count) commit(s)"
    }
}

# ── E6: Pre-deploy hook ───────────────────────────────────────────────────────
$preHook = Join-Path $PSScriptRoot "hooks\pre-deploy.ps1"
if (Test-Path $preHook) {
    Step "Running pre-deploy hook..."
    if ($DryRun) {
        DryRun "Would run hooks\pre-deploy.ps1"
    } else {
        & $preHook
        if ($LASTEXITCODE -ne 0) { ReleaseLock; Fail "Pre-deploy hook failed — deployment aborted" }
        Ok "Pre-deploy hook passed"
    }
}

# ── VPS: git pull ─────────────────────────────────────────────────────────────
Step "VPS: pulling latest changes..."
if ($DryRun) {
    DryRun "Would git pull origin $BRANCH on $SERVER_IP:$REMOTE_APP"
} else {
    # E1: Save current commit hash as rollback point before pulling new code
    # S4: accept-new avoids MITM by failing if host key changes unexpectedly
    RunRemote @"
cd $REMOTE_APP
git rev-parse HEAD > .git-shipps-last-deploy
GIT_SSH_COMMAND='ssh -i ~/.ssh/deploy_key -o StrictHostKeyChecking=accept-new' git pull origin $BRANCH
"@
    if ($LASTEXITCODE -ne 0) { ReleaseLock; Fail "git pull failed on VPS" }
    Ok "Code up to date on VPS"
    $commitHash = (git -C $PROJECT_ROOT rev-parse HEAD 2>$null)
    if (-not $commitHash) { $commitHash = "" }
}

# ── Docker compose up ─────────────────────────────────────────────────────────
Step "Building and starting Docker containers..."
if ($DryRun) {
    DryRun "Would run: docker compose -f $COMPOSE_FILE up -d --build"
} else {
    RunRemote @"
cd $REMOTE_APP
docker compose -f $COMPOSE_FILE up -d --build
"@
    if ($LASTEXITCODE -ne 0) { ReleaseLock; Fail "Docker build/start failed" }
    Ok "Containers started"
}

# ── Health check (optional) ───────────────────────────────────────────────────
$healthOk = $true
if ($HEALTH_URL -and -not $DryRun) {
    Step "Running health check..."
    Start-Sleep -Seconds 8
    # S3: HEALTH_URL is validated above — safe to pass to curl
    $health = SshCmd "curl -s -o /dev/null -w '%{http_code}' $HEALTH_URL"
    if (-not $health) { $health = "000" }
    if ($health -eq "200") {
        Ok "Health check passed (HTTP 200)"
    } else {
        $healthOk = $false
        Warn "Health check returned HTTP $health (service may still be starting)"
        Write-Host "   Check logs: ssh $SERVER 'docker compose -f $REMOTE_APP/$COMPOSE_FILE logs --tail 50'" -ForegroundColor Yellow
    }
} elseif ($HEALTH_URL -and $DryRun) {
    DryRun "Would check health at $HEALTH_URL"
}

# ── E6: Post-deploy hook ──────────────────────────────────────────────────────
$postHook = Join-Path $PSScriptRoot "hooks\post-deploy.ps1"
if ((Test-Path $postHook) -and -not $DryRun) {
    Step "Running post-deploy hook..."
    & $postHook
    if ($LASTEXITCODE -ne 0) { Warn "Post-deploy hook failed (deploy itself succeeded)" }
    else { Ok "Post-deploy hook passed" }
}

# ── E8: Release deploy lock ───────────────────────────────────────────────────
if (-not $DryRun) { ReleaseLock }

# ── E2: Write to deployment log ───────────────────────────────────────────────
if (-not $DryRun) {
    $elapsed   = [int]((Get-Date) - $DeployStart).TotalSeconds
    $logStatus = if ($healthOk) { "success" } else { "warning" }
    WriteLog $logStatus $finalMsg $commitHash $elapsed
}

# ── E4: Webhook notification ──────────────────────────────────────────────────
if ($WEBHOOK_URL -and -not $DryRun) {
    $envLabel   = if ($Env) { " [$Env]" } else { "" }
    $statusIcon = if ($healthOk) { ":white_check_mark:" } else { ":warning:" }
    $shortHash  = if ($commitHash) { $commitHash.Substring(0, [Math]::Min(7, $commitHash.Length)) } else { "n/a" }
    $payload    = @{
        text = "$statusIcon *git-shipps$envLabel* — Deploy to ``$SERVER_IP``\n> ``$shortHash`` $finalMsg"
    }
    try {
        Invoke-RestMethod -Uri $WEBHOOK_URL -Method Post -Body ($payload | ConvertTo-Json) -ContentType "application/json" | Out-Null
    } catch {
        Warn "Webhook notification failed: $_"
    }
}

# ── Done ──────────────────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Host ""
    Write-Host "================================================" -ForegroundColor DarkYellow
    Write-Host "  Dry-run complete — no changes were made." -ForegroundColor DarkYellow
    Write-Host "================================================" -ForegroundColor DarkYellow
    Write-Host ""
    exit 0
}

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
Write-Host "  .\deploy.ps1 -Rollback    # revert to previous deploy"
Write-Host "  .\deploy.ps1 -History     # show deployment log"
Write-Host "  .\deploy.ps1 -Status      # container status on VPS"
Write-Host ""
