# git-shipps — One-time VPS Setup Script
# ─────────────────────────────────────────────────────────────────────────────
# This script:
#   1. Generates a dedicated SSH deploy key (ed25519)
#   2. Copies the public key to your VPS
#   3. Adds the deploy key to the VPS's SSH authorized_keys
#   4. Clones your GitHub repository on the VPS
#   5. Prints next steps
#
# Usage:
#   .\setup-deploy-key.ps1 -ServerIP 1.2.3.4 -RepoUrl https://github.com/you/repo
#   .\setup-deploy-key.ps1 -ServerIP 1.2.3.4 -ServerUser ubuntu -RepoUrl https://github.com/you/repo -RemoteApp /home/ubuntu/myapp -KeyName myapp_deploy
# ─────────────────────────────────────────────────────────────────────────────

param(
    [Parameter(Mandatory)][string]$ServerIP,
    [Parameter(Mandatory)][string]$RepoUrl,
    [string]$ServerUser = "root",
    [string]$RemoteApp  = "",          # defaults to /home/<user>/<repo-name>
    [string]$KeyName    = "deploy_key"
)

# ── Input validation ─────────────────────────────────────────────────────────
# S1: Validate ServerIP — only alphanumeric, dots, hyphens (no shell metacharacters)
if ($ServerIP -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,253}$') {
    Write-Host "  ERROR: Invalid ServerIP format: '$ServerIP'" -ForegroundColor Red
    Write-Host "  Only alphanumeric characters, dots, and hyphens are allowed." -ForegroundColor Yellow
    exit 1
}

# S1: Validate RepoUrl — must be https://github.com/... or git@github.com:...
# Strictly disallow shell metacharacters to prevent command injection
if ($RepoUrl -notmatch '^(https://[a-zA-Z0-9._/-]+(\.git)?|git@[a-zA-Z0-9._-]+:[a-zA-Z0-9._/-]+(\.git)?)$') {
    Write-Host "  ERROR: Invalid RepoUrl format: '$RepoUrl'" -ForegroundColor Red
    Write-Host "  Must be https://host/user/repo or git@host:user/repo (no shell metacharacters)" -ForegroundColor Yellow
    exit 1
}

# S1: Validate RemoteApp path — only safe path characters
if ($RemoteApp -and $RemoteApp -notmatch '^[a-zA-Z0-9/_.-]+$') {
    Write-Host "  ERROR: Invalid RemoteApp path: '$RemoteApp'" -ForegroundColor Red
    Write-Host "  Only alphanumeric characters, /, _, ., - are allowed." -ForegroundColor Yellow
    exit 1
}

# S1: Validate ServerUser — only safe Unix username characters
if ($ServerUser -notmatch '^[a-zA-Z0-9_.-]+$') {
    Write-Host "  ERROR: Invalid ServerUser: '$ServerUser'" -ForegroundColor Red
    exit 1
}

# S1: Validate KeyName — only alphanumeric, underscores, hyphens
if ($KeyName -notmatch '^[a-zA-Z0-9_-]+$') {
    Write-Host "  ERROR: Invalid KeyName: '$KeyName'" -ForegroundColor Red
    exit 1
}

$KeyPath    = "$HOME\.ssh\$KeyName"
$KeyPathPub = "$KeyPath.pub"
$Server     = "$ServerUser@$ServerIP"

# Derive repo name from URL if RemoteApp not set
if (-not $RemoteApp) {
    $repoName  = ($RepoUrl -split "/")[-1] -replace "\.git$", ""
    $homeDir   = if ($ServerUser -eq "root") { "/root" } else { "/home/$ServerUser" }
    $RemoteApp = "$homeDir/$repoName"
}

Write-Host ""
Write-Host "git-shipps — VPS Setup" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Server:   $Server"
Write-Host "  Repo:     $RepoUrl"
Write-Host "  App path: $RemoteApp"
Write-Host "  SSH key:  $KeyPath"
Write-Host ""

# ── Step 1: Generate SSH key ─────────────────────────────────────────────────
Write-Host ">> [1/4] Generating SSH key..." -ForegroundColor Cyan
if (Test-Path $KeyPath) {
    Write-Host "   Key already exists at $KeyPath — skipping generation." -ForegroundColor Yellow
} else {
    # S6: Use empty string for passphrase — -N '""' would set literal "" as passphrase
    ssh-keygen -t ed25519 -f $KeyPath -N "" -C "git-shipps-deploy@$ServerIP"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   ERROR: ssh-keygen failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "   OK: Key generated at $KeyPath" -ForegroundColor Green
}

# ── Step 2: Copy public key to VPS ───────────────────────────────────────────
Write-Host ""
Write-Host ">> [2/4] Copying public key to VPS..." -ForegroundColor Cyan
Write-Host "   You may be prompted for your VPS password (one-time only)."
$pubKey = Get-Content $KeyPathPub
# S2: Use base64 encoding to safely transfer the public key — avoids shell injection
# via special characters that could appear in key comments or if the file is tampered
$pubKeyBytes = [System.Text.Encoding]::UTF8.GetBytes($pubKey)
$pubKeyB64   = [System.Convert]::ToBase64String($pubKeyBytes)
# S7: Check if key already exists before appending to prevent duplicate entries
$addKeyScript = @"
echo $pubKeyB64 | base64 -d > /tmp/git-shipps-newkey.pub
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
if ! grep -qF "`$(cat /tmp/git-shipps-newkey.pub)" ~/.ssh/authorized_keys 2>/dev/null; then
    cat /tmp/git-shipps-newkey.pub >> ~/.ssh/authorized_keys
    echo KEY_ADDED
else
    echo KEY_EXISTS
fi
rm -f /tmp/git-shipps-newkey.pub
"@
$addKeyBytes  = [System.Text.Encoding]::UTF8.GetBytes(($addKeyScript -replace "`r`n", "`n"))
$addKeyB64    = [System.Convert]::ToBase64String($addKeyBytes)
$addKeyResult = ssh "$Server" "echo $addKeyB64 | base64 -d | bash"
if ($LASTEXITCODE -ne 0) {
    Write-Host "   ERROR: Could not copy public key. Check SSH access to $Server." -ForegroundColor Red
    exit 1
}
if ($addKeyResult -match "KEY_EXISTS") {
    Write-Host "   OK: Public key already present on $Server (skipped duplicate)" -ForegroundColor Green
} else {
    Write-Host "   OK: Public key added to $Server" -ForegroundColor Green
}

# ── Step 3: Clone repo on VPS ────────────────────────────────────────────────
Write-Host ""
Write-Host ">> [3/4] Cloning repository on VPS..." -ForegroundColor Cyan
# S1: RepoUrl and RemoteApp are validated above — safe to interpolate into bash here
$cloneScript = @"
if [ -d "$RemoteApp/.git" ]; then
    echo "ALREADY_CLONED"
else
    git clone $RepoUrl $RemoteApp
fi
"@
$bytes  = [System.Text.Encoding]::UTF8.GetBytes(($cloneScript -replace "`r`n", "`n"))
$b64    = [System.Convert]::ToBase64String($bytes)
$result = ssh -i $KeyPath "$Server" "echo $b64 | base64 -d | bash"
if ($result -eq "ALREADY_CLONED") {
    Write-Host "   OK: Repo already cloned at $RemoteApp" -ForegroundColor Green
} elseif ($LASTEXITCODE -ne 0) {
    Write-Host "   ERROR: git clone failed on VPS." -ForegroundColor Red
    Write-Host "   Make sure the repo is public, or add a GitHub deploy key for private repos." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "   OK: Repo cloned to $RemoteApp" -ForegroundColor Green
}

# ── Step 4: Print next steps ─────────────────────────────────────────────────
Write-Host ""
Write-Host ">> [4/4] Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Next steps:" -ForegroundColor Green
Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  1. Copy deploy.config.example.ps1 to deploy.config.ps1:"
Write-Host "     cp deploy.config.example.ps1 deploy.config.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "  2. Fill in your values in deploy.config.ps1:"
Write-Host "     `$SERVER_USER  = `"$ServerUser`""
Write-Host "     `$SERVER_IP    = `"$ServerIP`""
Write-Host "     `$REMOTE_APP   = `"$RemoteApp`""
Write-Host "     `$DEPLOY_KEY   = `"$KeyPath`""
Write-Host ""
Write-Host "  3. Create your .env file on the VPS:"
Write-Host "     ssh -i $KeyPath $Server" -ForegroundColor Cyan
Write-Host "     nano $RemoteApp/.env" -ForegroundColor Cyan
Write-Host ""
Write-Host "  4. Deploy:"
Write-Host "     .\deploy.ps1 `"initial deploy`"" -ForegroundColor Cyan
Write-Host ""

# ── Note for private GitHub repos ────────────────────────────────────────────
Write-Host "  NOTE: If your GitHub repo is private, add a deploy key:" -ForegroundColor Yellow
Write-Host "  → Go to: https://github.com/$($RepoUrl -replace 'https://github.com/','')/settings/keys"
Write-Host "  → Add new deploy key → paste contents of: $KeyPathPub"
Write-Host "  → On the VPS, configure git to use the key:"
Write-Host "    git config -C $RemoteApp core.sshCommand 'ssh -i ~/.ssh/deploy_key'" -ForegroundColor DarkGray
Write-Host ""
