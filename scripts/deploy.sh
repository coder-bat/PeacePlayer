#!/bin/bash
# Local deployment script - Run this on your server
# This is a fallback if you don't use GitHub Actions

set -e

# Configuration
APP_NAME="viralmusic"
APP_DIR="$HOME/ViralMusic"
BACKUP_DIR="$HOME/backups/$APP_NAME-$(date +%Y%m%d-%H%M%S)"
REPO_URL="${1:-}"  # Pass repo URL as argument
BRANCH="${2:-main}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Check if directory exists
if [ ! -d "$APP_DIR" ]; then
    if [ -z "$REPO_URL" ]; then
        error "App directory not found and no repo URL provided.\nUsage: $0 <repo-url> [branch]"
    fi
    log "Cloning repository..."
    git clone "$REPO_URL" "$APP_DIR"
fi

cd "$APP_DIR"

# Create backup
log "Creating backup at $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
if [ -d "backend" ]; then
    cp -r backend "$BACKUP_DIR/"
fi

# Pull latest changes
log "Pulling latest changes from $BRANCH..."
git fetch origin
git reset --hard "origin/$BRANCH"

# Check which deployment method to use
if [ -f "docker-compose.yml" ]; then
    log "Docker deployment detected..."
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        error "Docker not found. Please install Docker first."
    fi
    
    # Build and deploy
    docker-compose build --no-cache
    docker-compose up -d --remove-orphans
    
    # Cleanup
    docker image prune -f
    
    # Health check
    sleep 5
    if curl -f http://localhost:6060/ > /dev/null 2>&1; then
        log "✅ Docker deployment successful!"
    else
        error "Health check failed!"
    fi
    
else
    log "Standard deployment detected..."
    
    cd backend
    
    # Setup/update Python environment
    if [ ! -d "venv" ]; then
        log "Creating virtual environment..."
        python3 -m venv venv
    fi
    
    log "Installing/updating dependencies..."
    ./venv/bin/pip install --upgrade pip
    ./venv/bin/pip install -r requirements.txt
    
    # Determine service manager
    if command -v systemctl &> /dev/null && [ -f "/etc/systemd/system/$APP_NAME.service" ]; then
        log "Restarting systemd service..."
        sudo systemctl restart viralmusic
        sudo systemctl status viralmusic --no-pager
        
    elif command -v supervisorctl &> /dev/null; then
        log "Restarting supervisor service..."
        sudo supervisorctl restart viralmusic || sudo supervisorctl start viralmusic
        sudo supervisorctl status viralmusic
        
    else
        log "No service manager found, using manual restart..."
        pkill -f "python server.py" || true
        sleep 2
        nohup ./venv/bin/python server.py > server.log 2>&1 &
        sleep 2
    fi
    
    # Health check
    if curl -f http://localhost:6060/ > /dev/null 2>&1; then
        log "✅ Deployment successful!"
        curl -s http://localhost:6060/ | grep -o '"status":"[^"]*"' || true
    else
        error "Health check failed! Rolling back..."
        # Simple rollback: restore backup
        if [ -d "$BACKUP_DIR/backend" ]; then
            cp -r "$BACKUP_DIR/backend"/* .
            warn "Rolled back to previous version. Check logs for errors."
        fi
        exit 1
    fi
fi

log "🎉 Deployment complete!"
log "Backup saved at: $BACKUP_DIR"
