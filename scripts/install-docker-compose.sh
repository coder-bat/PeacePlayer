#!/bin/bash
# Install Docker Compose on Ubuntu/Debian-based systems

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[DOCKER-COMPOSE] $1${NC}"; }
info() { echo -e "${BLUE}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

log "Installing Docker Compose on Ubuntu/Debian"
echo ""

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    warn "Docker not found. Installing Docker first..."
    
    # Install Docker
    log "Installing Docker..."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add repository
    echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Add user to docker group
    sudo usermod -aG docker $USER
    warn "You need to logout and login again for Docker group changes to take effect"
    
    log "✓ Docker installed"
else
    info "Docker already installed ✓"
fi

# Check Docker Compose version
log "Checking Docker Compose..."

# Method 1: Check for docker compose (v2 - plugin)
if docker compose version &> /dev/null; then
    log "✓ Docker Compose V2 (plugin) is available"
    info "Use: docker compose (space, not hyphen)"
    
    # Create alias for convenience
    if ! grep -q "alias docker-compose" ~/.bashrc 2>/dev/null; then
        echo "alias docker-compose='docker compose'" >> ~/.bashrc
        log "Added alias: docker-compose -> docker compose"
    fi
    
    COMPOSE_CMD="docker compose"
    
# Method 2: Check for docker-compose (v1 - standalone)
elif command -v docker-compose &> /dev/null; then
    VERSION=$(docker-compose --version)
    log "✓ Docker Compose V1 found: $VERSION"
    COMPOSE_CMD="docker-compose"
    
# Method 3: Install docker-compose-plugin
else
    log "Installing Docker Compose plugin..."
    
    # Try to install via apt (recommended for Ubuntu)
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
    
    if docker compose version &> /dev/null; then
        log "✓ Docker Compose V2 installed successfully"
        
        # Create alias
        if ! grep -q "alias docker-compose" ~/.bashrc 2>/dev/null; then
            echo "alias docker-compose='docker compose'" >> ~/.bashrc
            log "Added alias: docker-compose -> docker compose"
        fi
        
        COMPOSE_CMD="docker compose"
    else
        # Fallback: Install standalone docker-compose v1
        warn "Plugin installation failed. Installing standalone docker-compose..."
        
        # Get latest version
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d'"' -f4)
        COMPOSE_VERSION=${COMPOSE_VERSION:-v2.23.0}
        
        # Download
        sudo curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        
        # Create symlink
        sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
        
        log "✓ Docker Compose V1 installed: $(docker-compose --version)"
        COMPOSE_CMD="docker-compose"
    fi
fi

echo ""
log "Installation Complete! 🎉"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Docker Compose command: $COMPOSE_CMD"
echo ""

if [ "$COMPOSE_CMD" = "docker compose" ]; then
    echo "💡 Tip: You can use either:"
    echo "   docker compose up -d       (V2 - recommended)"
    echo "   docker-compose up -d       (alias - after reloading shell)"
    echo ""
    echo "To use the alias now, run:"
    echo "   source ~/.bashrc"
else
    echo "💡 Using: docker-compose (V1)"
fi

echo ""
echo "Test with:"
echo "   $COMPOSE_CMD --version"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Note about group membership
if groups $USER | grep -q '\bdocker\b'; then
    : # User is in docker group
else
    warn "⚠️  You need to logout and login again to use Docker without sudo"
    warn "   Or run: newgrp docker"
fi
