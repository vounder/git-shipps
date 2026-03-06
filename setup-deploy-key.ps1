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
    ssh-keygen -t ed25519 -f $KeyPath -N '""' -C "git-shipps-deploy@$ServerIP"
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
ssh "$Server" "mkdir -p ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
if ($LASTEXITCODE -ne 0) {
    Write-Host "   ERROR: Could not copy public key. Check SSH access to $Server." -ForegroundColor Red
    exit 1
}
Write-Host "   OK: Public key added to $Server" -ForegroundColor Green

# ── Step 3: Clone repo on VPS ────────────────────────────────────────────────
Write-Host ""
Write-Host ">> [3/4] Cloning repository on VPS..." -ForegroundColor Cyan
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
