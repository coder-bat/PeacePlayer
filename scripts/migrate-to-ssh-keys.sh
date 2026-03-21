#!/bin/bash
# Helper script to migrate from password to SSH key authentication
# This can be run locally or on the server

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}$1${NC}"; }
info() { echo -e "${BLUE}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }

cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║     🔐 Migration: Password → SSH Key Authentication            ║
╠════════════════════════════════════════════════════════════════╣
║                                                                ║
║  This script helps you migrate from password to SSH keys       ║
║  for more secure GitHub Actions deployments.                   ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝

EOF

read -p "Are you running this on your LOCAL machine (not server)? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    warn "This script should be run on your LOCAL machine."
    warn "The SSH key needs to be generated locally and added to GitHub."
    exit 1
fi

echo ""
log "Step 1: Generate SSH Key Pair"
echo ""

KEY_NAME="viralmusic-deploy"
KEY_PATH="$HOME/.ssh/$KEY_NAME"

if [ -f "$KEY_PATH" ]; then
    warn "SSH key already exists at $KEY_PATH"
    read -p "Overwrite? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Using existing key."
    else
        rm -f "$KEY_PATH" "$KEY_PATH.pub"
        ssh-keygen -t ed25519 -C "viralmusic-deploy" -f "$KEY_PATH" -N ""
    fi
else
    ssh-keygen -t ed25519 -C "viralmusic-deploy" -f "$KEY_PATH" -N ""
    log "✓ SSH key generated"
fi

echo ""
log "Step 2: Copy Public Key to Server"
echo ""

read -p "Server IP/hostname: " SERVER_HOST
read -p "Server username: " SERVER_USER
read -p "SSH port [22]: " SERVER_PORT
SERVER_PORT=${SERVER_PORT:-22}

info "You'll need to enter your password one more time..."
echo ""

# Copy public key to server
if ssh-copy-id -i "$KEY_PATH.pub" -p "$SERVER_PORT" "$SERVER_USER@$SERVER_HOST"; then
    log "✓ Public key copied to server"
else
    warn "ssh-copy-id failed. Trying manual method..."
    
    # Manual method
    PUB_KEY=$(cat "$KEY_PATH.pub")
    ssh -p "$SERVER_PORT" "$SERVER_USER@$SERVER_HOST" "mkdir -p ~/.ssh && echo '$PUB_KEY' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
    log "✓ Public key added manually"
fi

# Test connection
echo ""
log "Step 3: Test SSH Key Connection"
echo ""

if ssh -i "$KEY_PATH" -p "$SERVER_PORT" -o PasswordAuthentication=no "$SERVER_USER@$SERVER_HOST" "echo 'SSH key works!'"; then
    log "✓ SSH key authentication successful!"
else
    warn "✗ SSH key authentication failed"
    warn "Check your server SSH configuration"
    exit 1
fi

echo ""
log "Step 4: Update GitHub Secrets"
echo ""

warn "Add these secrets to GitHub:"
echo ""
echo "  1. Go to: https://github.com/YOUR_USERNAME/ViralMusic/settings/secrets/actions"
echo ""
echo "  2. Add these secrets:"
echo ""
echo "     SERVER_HOST       → $SERVER_HOST"
echo "     SERVER_USER       → $SERVER_USER"
echo "     SERVER_PORT       → $SERVER_PORT"
echo ""
echo "  3. Add SSH_PRIVATE_KEY:"
echo "     (Copy the content below)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$KEY_PATH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

read -p "Press Enter after adding secrets to GitHub..."

echo ""
log "Step 5: Switch to SSH Key Workflow"
echo ""

if [ -f ".github/workflows/deploy-ssh.yml" ]; then
    mv .github/workflows/deploy.yml .github/workflows/deploy-password.yml
    mv .github/workflows/deploy-ssh.yml .github/workflows/deploy.yml
    log "✓ Switched to SSH key workflow"
    
    git add .github/workflows/
    git commit -m "Switch to SSH key authentication" 2>/dev/null || true
    warn "Don't forget to push: git push origin main"
else
    warn "SSH workflow not found. Make sure you're in the git repository."
fi

echo ""
log "Step 6: Disable Password Auth (Optional but Recommended)"
echo ""

read -p "Disable password authentication on server? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    ssh -i "$KEY_PATH" -p "$SERVER_PORT" "$SERVER_USER@$SERVER_HOST" "
        sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
        sudo systemctl restart sshd
        echo 'Password authentication disabled'
    "
    log "✓ Password authentication disabled"
fi

echo ""
log "Migration Complete! 🎉"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Your deployments now use SSH keys!"
echo ""
echo "Benefits:"
echo "  ✓ More secure than passwords"
echo "  ✓ Can't be brute-forced"
echo "  ✓ Easy to revoke if needed"
echo "  ✓ No password prompts"
echo ""
echo "Next deployment:"
echo "  git push origin main"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
