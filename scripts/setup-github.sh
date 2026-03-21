#!/bin/bash
# Quick setup script for GitHub-based deployment
# Run this after creating your GitHub repo

set -e

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}$1${NC}"; }
info() { echo -e "${BLUE}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }

cat << 'EOF'
╔══════════════════════════════════════════════════════════╗
║     ViralMusic GitHub Deployment Setup Assistant            ║
╚══════════════════════════════════════════════════════════╝

This script helps you set up automated deployments via GitHub.
EOF

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
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    if [ ! -z "$REMOTE_URL" ]; then
        info "Remote: $REMOTE_URL"
    fi
fi

echo ""
log "Step 2: GitHub Actions Workflows"
info "The following workflows are configured:"
echo "  ✓ deploy.yml - Auto-deploy on push to main"
echo "  ✓ docker-deploy.yml - Docker build & deploy"
echo "  ✓ release.yml - Create releases on tags"
echo ""

log "Step 3: Server Configuration"
echo ""
echo "You need to add these secrets to GitHub:"
echo ""
echo "  1. Go to: https://github.com/$(git remote get-url origin | sed 's/.*github.com[:\/]//;s/\.git$//')/settings/secrets/actions"
echo ""
echo "  2. Add these secrets:"
echo "     ┌─────────────────────┬────────────────────────────────────┐"
echo "     │ SERVER_HOST         │ Your server IP (e.g., 123.456.789.0)│"
echo "     │ SERVER_USER         │ SSH username (e.g., ubuntu)         │"
echo "     │ SSH_PRIVATE_KEY     │ Your SSH private key content        │"
echo "     │ SERVER_PORT         │ SSH port (default: 22)              │"
echo "     └─────────────────────┴────────────────────────────────────┘"
echo ""

# Generate SSH key if needed
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
    warn "No SSH key found. Generate one now?"
    read -p "Generate SSH key? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        ssh-keygen -t ed25519 -C "viralmusic-deploy" -f "$HOME/.ssh/id_ed25519" -N ""
        log "SSH key generated!"
        echo ""
        info "Public key (add to server's ~/.ssh/authorized_keys):"
        cat "$HOME/.ssh/id_ed25519.pub"
        echo ""
        info "Private key (add to GitHub secrets as SSH_PRIVATE_KEY):"
        cat "$HOME/.ssh/id_ed25519"
        echo ""
    fi
else
    info "SSH key already exists ✓"
fi

echo ""
log "Step 4: Deployment Options"
echo ""
echo "Choose your deployment method:"
echo ""
echo "A) Standard Python (Supervisor/Systemd)"
echo "   - Simpler setup"
echo "   - Direct code deployment"
echo ""
echo "B) Docker (Recommended)"
echo "   - Containerized, isolated"
echo "   - Automatic image builds"
echo "   - Easier rollbacks"
echo ""

read -p "Select option (A/b): " DEPLOY_OPTION
DEPLOY_OPTION=${DEPLOY_OPTION:-A}

if [[ $DEPLOY_OPTION =~ ^[Bb]$ ]]; then
    echo ""
    log "Docker Deployment Selected"
    info "Make sure to update docker-compose.yml:"
    info "  Change: ghcr.io/YOUR_USERNAME/ViralMusic/ytaudio-backend:main"
    info "  To:     ghcr.io/$(git remote get-url origin | sed 's/.*github.com[:\/]//;s/\.git$//')/ytaudio-backend:main"
    
    # Try to auto-update
    REPO_PATH=$(git remote get-url origin 2>/dev/null | sed 's/.*github.com[:\/]//;s/\.git$//' || echo "YOUR_USERNAME/ViralMusic")
    sed -i.bak "s|ghcr.io/YOUR_USERNAME/ViralMusic/ytaudio-backend|ghcr.io/$REPO_PATH/ytaudio-backend|g" docker-compose.yml 2>/dev/null || true
    rm -f docker-compose.yml.bak
    
    echo ""
    warn "To deploy to server, run:"
    warn "  scp -r . user@your-server:~/ViralMusic"
    warn "  ssh user@your-server 'cd ~/ViralMusic && ./scripts/install.sh'"
else
    echo ""
    log "Standard Python Deployment Selected"
    warn "To deploy to server, run:"
    warn "  scp -r . user@your-server:~/ViralMusic"
    warn "  ssh user@your-server 'cd ~/ViralMusic && ./scripts/install.sh'"
fi

echo ""
log "Step 5: Testing Deployment"
echo ""
echo "After setup, test the deployment:"
echo "  1. Make a small change to backend/server.py"
echo "  2. Commit and push:"
echo "       git add ."
echo "       git commit -m 'Test deployment'"
echo "       git push origin main"
echo "  3. Watch deployment at:"
echo "       https://github.com/$(git remote get-url origin 2>/dev/null | sed 's/.*github.com[:\/]//;s/\.git$//' || echo 'YOUR_USERNAME/ViralMusic')/actions"
echo ""

log "Setup Complete! 🎉"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Add GitHub secrets (see Step 3)"
echo "  2. Copy code to server (see Step 4)"
echo "  3. Run install.sh on server"
echo "  4. Push a test commit"
echo ""
echo "Documentation: DEPLOYMENT.md"
echo ""
