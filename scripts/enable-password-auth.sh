#!/bin/bash
# Script to enable password authentication on the server
# Run this ON THE SERVER, not locally

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[SERVER] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

if [ "$EUID" -ne 0 ]; then 
    error "Please run as root or with sudo"
    exit 1
fi

log "Enabling Password Authentication for ViralMusic SSH"
echo ""

# Backup original config
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="$SSHD_CONFIG.backup.$(date +%Y%m%d-%H%M%S)"

cp $SSHD_CONFIG $BACKUP
log "Backup created: $BACKUP"

# Check current settings
echo ""
info "Current SSH authentication settings:"
grep -E "^(PasswordAuthentication|ChallengeResponseAuthentication|PermitRootLogin)" $SSHD_CONFIG || echo "  (using defaults)"

echo ""
warn "⚠️  WARNING: Password authentication is less secure than SSH keys"
warn "   Only enable this if you understand the risks!"
echo ""
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Cancelled. No changes made."
    exit 0
fi

# Update SSH config
log "Updating SSH configuration..."

# Enable password authentication
if grep -q "^#*PasswordAuthentication" $SSHD_CONFIG; then
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' $SSHD_CONFIG
else
    echo "PasswordAuthentication yes" >> $SSHD_CONFIG
fi

# Enable challenge response (for some older systems)
if grep -q "^#*ChallengeResponseAuthentication" $SSHD_CONFIG; then
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' $SSHD_CONFIG
else
    echo "ChallengeResponseAuthentication yes" >> $SSHD_CONFIG
fi

# Optional: Disable root login with password (safer)
read -p "Disable root login with password? (recommended) (Y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    if grep -q "^#*PermitRootLogin" $SSHD_CONFIG; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' $SSHD_CONFIG
    else
        echo "PermitRootLogin prohibit-password" >> $SSHD_CONFIG
    fi
    log "Root password login disabled"
fi

# Test configuration
log "Testing SSH configuration..."
if sshd -t; then
    log "✓ SSH configuration valid"
else
    error "✗ SSH configuration invalid!"
    error "Restoring backup..."
    cp $BACKUP $SSHD_CONFIG
    exit 1
fi

# Restart SSH
log "Restarting SSH service..."
if systemctl restart sshd || service ssh restart; then
    log "✓ SSH service restarted"
else
    error "Failed to restart SSH service"
    exit 1
fi

# Verify
log "Verifying configuration..."
if grep -q "^PasswordAuthentication yes" $SSHD_CONFIG; then
    log "✓ Password authentication enabled"
else
    warn "Could not verify password authentication setting"
fi

echo ""
log "Done! 🎉"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Password authentication is now enabled."
echo ""
echo "Next steps:"
echo "  1. Set a strong password if not set:"
echo "       sudo passwd $USER"
echo ""
echo "  2. Add to GitHub Secrets:"
echo "       SERVER_PASSWORD = your-password"
echo ""
echo "  3. Test deployment with:"
echo "       git push origin main"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚠️  SECURITY RECOMMENDATIONS:"
echo ""
echo "1. Use a STRONG password (16+ characters)"
echo "2. Change SSH port from default (22):"
echo "     sudo nano /etc/ssh/sshd_config"
echo "     # Change: Port 2222"
echo "     sudo systemctl restart sshd"
echo ""
echo "3. Install fail2ban:"
echo "     sudo apt install fail2ban"
echo ""
echo "4. Consider switching to SSH keys later:"
echo "     ./scripts/migrate-to-ssh-keys.sh"
echo ""
