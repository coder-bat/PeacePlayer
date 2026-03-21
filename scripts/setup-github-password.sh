#!/bin/bash
# Setup script for GitHub Actions with Password Authentication
# ⚠️  WARNING: Password auth is less secure than SSH keys

set -e

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}$1${NC}"; }
info() { echo -e "${BLUE}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }
error() { echo -e "${RED}$1${NC}"; }

cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║     ⚠️  SECURITY WARNING - Password Authentication             ║
╠════════════════════════════════════════════════════════════════╣
║                                                                ║
║  Password authentication is LESS SECURE than SSH keys:         ║
║                                                                ║
║  ❌ Passwords can be brute-forced                              ║
║  ❌ Password stored in GitHub (encrypted, but still...)        ║
║  ❌ Harder to rotate/change securely                           ║
║                                                                ║
║  ✅ SSH keys are recommended for production use!               ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝

EOF

read -p "Continue with password authentication? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Exiting. To use SSH keys instead, run: ./scripts/setup-github.sh"
    exit 0
fi

echo ""
log "GitHub Actions Password Authentication Setup"
echo ""

# Check if git repo exists
if [ ! -d ".git" ]; then
    log "Step 1: Initialize Git Repository"
    echo ""
    read -p "Enter your GitHub username: " GITHUB_USER
    read -p "Enter repository name [ViralMusic]: " REPO_NAME
    REPO_NAME=${REPO_NAME:-ViralMusic}
    
    git init
    git add .
    git commit -m "Initial commit"
    git branch -M main
    git remote add origin "https://github.com/$GITHUB_USER/$REPO_NAME.git"
    
    warn "Repository initialized!"
    warn "Now create the repo on GitHub and run:"
    warn "  git push -u origin main"
    echo ""
    read -p "Press Enter after creating GitHub repo and pushing..."
else
    info "Git repository already initialized ✓"
fi

echo ""
log "Step 2: Configure Workflows for Password Auth"
echo ""

# Rename password workflows to active
if [ -f ".github/workflows/deploy-password.yml" ]; then
    mv .github/workflows/deploy.yml .github/workflows/deploy-ssh.yml 2>/dev/null || true
    mv .github/workflows/deploy-password.yml .github/workflows/deploy.yml
    info "✓ Enabled password-based deployment workflow"
fi

if [ -f ".github/workflows/docker-deploy-password.yml" ]; then
    mv .github/workflows/docker-deploy.yml .github/workflows/docker-deploy-ssh.yml 2>/dev/null || true
    mv .github/workflows/docker-deploy-password.yml .github/workflows/docker-deploy.yml
    info "✓ Enabled password-based Docker workflow"
fi

git add .github/workflows/
git commit -m "Configure password-based deployment" 2>/dev/null || true

echo ""
log "Step 3: GitHub Secrets Configuration"
echo ""
echo "You need to add these secrets to GitHub:"
echo ""
echo "  1. Go to: https://github.com/$(git remote get-url origin 2>/dev/null | sed 's/.*github.com[:\/]//;s/\.git$//' || echo 'YOUR_USERNAME/ViralMusic')/settings/secrets/actions"
echo ""
echo "  2. Add these secrets:"
echo "     ┌─────────────────────┬────────────────────────────────────┐"
echo "     │ SERVER_HOST         │ Your server IP (e.g., 123.456.789.0)│"
echo "     │ SERVER_USER         │ SSH username (e.g., ubuntu)         │"
echo "     │ SERVER_PASSWORD     │ Your SSH password                   │"
echo "     │ SERVER_PORT         │ SSH port (default: 22)              │"
echo "     └─────────────────────┴────────────────────────────────────┘"
echo ""

log "Step 4: Enable Password Authentication on Server"
echo ""
echo "⚠️  Your server must have password authentication enabled."
echo ""
echo "To enable on Ubuntu/Debian:"
echo "  1. SSH into your server:"
echo "       ssh user@your-server"
echo ""
echo "  2. Edit SSH config:"
echo "       sudo nano /etc/ssh/sshd_config"
echo ""
echo "  3. Ensure these lines exist:"
echo "       PasswordAuthentication yes"
echo "       ChallengeResponseAuthentication yes"
echo ""
echo "  4. Restart SSH:"
echo "       sudo systemctl restart sshd"
echo ""

read -p "Have you enabled password auth on the server? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    warn "Please enable password auth on your server first!"
fi

echo ""
log "Step 5: Server Setup"
echo ""
echo "Choose deployment method:"
echo ""
echo "1) Docker (Recommended)"
echo "2) Python + Supervisor"
echo "3) Python + Systemd"
echo ""
read -p "Select option [1-3]: " DEPLOY_METHOD

case $DEPLOY_METHOD in
    1) METHOD="docker" ;;
    2) METHOD="supervisor" ;;
    3) METHOD="systemd" ;;
    *) METHOD="docker" ;;
esac

echo ""
warn "To setup your server, run these commands:"
echo ""
echo "  # SSH to server"
echo "  ssh user@your-server"
echo ""
echo "  # Clone repository"
echo "  git clone https://github.com/$(git remote get-url origin 2>/dev/null | sed 's/.*github.com[:\/]//;s/\.git$//' || echo 'YOUR_USERNAME/ViralMusic').git ~/ViralMusic"
echo "  cd ~/ViralMusic"
echo ""
echo "  # Run installer with $METHOD"
echo "  chmod +x scripts/install.sh"
echo "  ./scripts/install.sh"
echo ""

echo ""
log "Setup Complete! 🎉"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚠️  IMPORTANT SECURITY NOTES:"
echo ""
echo "1. Your password is stored encrypted in GitHub, but:"
echo "   - Anyone with repo admin access can see it"
echo "   - It's transmitted during each deployment"
echo ""
echo "2. Consider switching to SSH keys in the future:"
echo "   - Generate key: ssh-keygen -t ed25519"
echo "   - Add to server: ~/.ssh/authorized_keys"
echo "   - Update GitHub secret: SSH_PRIVATE_KEY"
echo "   - Switch to deploy-ssh.yml workflow"
echo ""
echo "3. Restrict SSH access on your server:"
echo "   - Use firewall to limit SSH to GitHub IPs"
echo "   - Change default SSH port (22)"
echo "   - Enable fail2ban"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
