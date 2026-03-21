#!/bin/bash
# Initial server setup script
# Run this once on a fresh server

set -e

APP_NAME="viralmusic"
APP_DIR="$HOME/ViralMusic"
REPO_URL="${1:-}"
BRANCH="${2:-main}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INSTALL] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

# Check if running on supported OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
else
    OS=$(uname -s)
fi

log "Setting up YTAudio on $OS..."

# Install system dependencies
log "Installing system dependencies..."
if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
    sudo apt-get update
    sudo apt-get install -y \
        python3 \
        python3-venv \
        python3-pip \
        ffmpeg \
        git \
        curl \
        supervisor
        
    # Optional: Install Docker
    if ! command -v docker &> /dev/null; then
        warn "Docker not found. Install Docker for containerized deployment?"
        read -p "Install Docker? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            sudo usermod -aG docker $USER
            rm get-docker.sh
            log "Docker installed. You may need to logout and login again."
        fi
    fi
    
elif [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Fedora"* ]] || [[ "$OS" == *"Red Hat"* ]]; then
    sudo yum install -y \
        python3 \
        python3-pip \
        ffmpeg \
        git \
        curl
else
    warn "Unsupported OS. Please install dependencies manually:"
    warn "- Python 3.10+"
    warn "- ffmpeg"
    warn "- git"
    warn "- supervisor (optional)"
fi

# Clone repository if URL provided
if [ ! -z "$REPO_URL" ]; then
    if [ -d "$APP_DIR" ]; then
        warn "Directory $APP_DIR already exists."
        read -p "Remove and reclone? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$APP_DIR"
            git clone -b "$BRANCH" "$REPO_URL" "$APP_DIR"
        fi
    else
        git clone -b "$BRANCH" "$REPO_URL" "$APP_DIR"
    fi
fi

if [ ! -d "$APP_DIR" ]; then
    echo "Error: App directory not found at $APP_DIR"
    echo "Please provide repo URL: $0 <repo-url>"
    exit 1
fi

cd "$APP_DIR"

# Setup deployment keys for GitHub (optional)
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
    warn "No SSH key found. Generate one for GitHub access?"
    read -p "Generate SSH key? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ssh-keygen -t ed25519 -C "viralmusic-deploy" -f "$HOME/.ssh/id_rsa" -N ""
        log "SSH key generated. Add this public key to GitHub:"
        cat "$HOME/.ssh/id_rsa.pub"
        read -p "Press Enter after adding the key to GitHub..."
    fi
fi

# Choose deployment method
log "Choose deployment method:"
echo "1) Docker (Recommended - easiest updates)"
echo "2) Supervisor (Traditional Python)"
echo "3) Systemd (Native Linux service)"
echo "4) Manual (Just setup, you start it)"
read -p "Enter choice [1-4]: " DEPLOY_METHOD

 case $DEPLOY_METHOD in
    1)
        log "Setting up Docker deployment..."
        
        if ! command -v docker &> /dev/null; then
            echo "Error: Docker not installed. Please install Docker first."
            exit 1
        fi
        
        # Create data directories
        mkdir -p data/library data/logs
        
        # Build and start
        docker-compose build
        docker-compose up -d
        
        # Setup auto-update (optional)
        read -p "Enable automatic updates? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker-compose --profile auto-update up -d
            log "Auto-updates enabled via Watchtower"
        fi
        
        # Create update script
        cat > "$HOME/update-viralmusic.sh" << 'EOF'
#!/bin/bash
cd ~/ViralMusic
git pull
docker-compose pull
docker-compose up -d
docker image prune -f
echo "Update complete!"
EOF
        chmod +x "$HOME/update-viralmusic.sh"
        ;;
        
    2)
        log "Setting up Supervisor deployment..."
        
        # Setup Python environment
        cd backend
        python3 -m venv venv
        ./venv/bin/pip install --upgrade pip
        ./venv/bin/pip install -r requirements.txt
        
        # Create supervisor config
        sudo tee /etc/supervisor/conf.d/$APP_NAME.conf > /dev/null << EOF
[program:$APP_NAME]
directory=$APP_DIR/backend
command=$APP_DIR/backend/venv/bin/python server.py
autostart=true
autorestart=true
stderr_logfile=/var/log/$APP_NAME.err.log
stdout_logfile=/var/log/$APP_NAME.out.log
environment=PORT="6060",HOST="0.0.0.0"
user=$USER
EOF
        
        sudo supervisorctl reread
        sudo supervisorctl update
        sudo supervisorctl start viralmusic
        
        log "Supervisor service configured"
        
        # Create update script
        cat > "$HOME/update-viralmusic.sh" << EOF
#!/bin/bash
cd $APP_DIR
git pull
sudo supervisorctl restart viralmusic
echo "Update complete!"
EOF
        chmod +x "$HOME/update-viralmusic.sh"
        ;;
        
    3)
        log "Setting up Systemd deployment..."
        
        # Setup Python environment
        cd backend
        python3 -m venv venv
        ./venv/bin/pip install --upgrade pip
        ./venv/bin/pip install -r requirements.txt
        
        # Create systemd service
        sudo tee /etc/systemd/system/$APP_NAME.service > /dev/null << EOF
[Unit]
Description=YTAudio Backend Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$APP_DIR/backend
Environment="PORT=6060"
Environment="HOST=0.0.0.0"
Environment="PYTHONUNBUFFERED=1"
ExecStart=$APP_DIR/backend/venv/bin/python server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        
        sudo systemctl daemon-reload
        sudo systemctl enable viralmusic
        sudo systemctl start viralmusic
        
        log "Systemd service configured"
        
        # Create update script
        cat > "$HOME/update-viralmusic.sh" << EOF
#!/bin/bash
cd $APP_DIR
git pull
sudo systemctl restart viralmusic
sudo systemctl status viralmusic --no-pager
echo "Update complete!"
EOF
        chmod +x "$HOME/update-viralmusic.sh"
        ;;
        
    4)
        log "Setting up manual deployment..."
        
        cd backend
        python3 -m venv venv
        ./venv/bin/pip install --upgrade pip
        ./venv/bin/pip install -r requirements.txt
        
        warn "Setup complete. Start the server manually with:"
        warn "  cd $APP_DIR/backend && ./venv/bin/python server.py"
        
        # Create start script
        cat > "$HOME/start-viralmusic.sh" << EOF
#!/bin/bash
cd $APP_DIR/backend
./venv/bin/python server.py
EOF
        chmod +x "$HOME/start-viralmusic.sh"
        ;;
        
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

# Setup firewall (optional)
if command -v ufw &> /dev/null; then
    warn "Firewall detected. Open port 6060?"
    read -p "Open port 6060? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo ufw allow 6060/tcp
        log "Port 6060 opened"
    fi
fi

# Final status
log "Setup complete! 🎉"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  YTAudio Backend Server"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📂 Installation directory: $APP_DIR"
echo "🌐 Server URL: http://$(hostname -I | awk '{print $1}'):6060"
echo ""

if [ -f "$HOME/update-viralmusic.sh" ]; then
    echo "🔄 Update script: ~/update-viralmusic.sh"
    echo "   Usage: ~/update-viralmusic.sh"
    echo ""
fi

if [ "$DEPLOY_METHOD" == "1" ]; then
    echo "🐳 Docker commands:"
    echo "   View logs: docker-compose logs -f"
    echo "   Restart:   docker-compose restart"
    echo "   Stop:      docker-compose down"
elif [ "$DEPLOY_METHOD" == "2" ]; then
    echo "🔧 Supervisor commands:"
    echo "   Status:  sudo supervisorctl status viralmusic"
    echo "   Restart: sudo supervisorctl restart viralmusic"
    echo "   Logs:    sudo tail -f /var/log/$APP_NAME.out.log"
elif [ "$DEPLOY_METHOD" == "3" ]; then
    echo "🔧 Systemd commands:"
    echo "   Status:  sudo systemctl status viralmusic"
    echo "   Restart: sudo systemctl restart $APP_NAME"
    echo "   Logs:    sudo journalctl -u $APP_NAME -f"
fi

echo ""
echo "📖 Next steps:"
echo "   1. Configure GitHub secrets for automated deployments"
echo "   2. Update iOS app to point to: http://$(hostname -I | awk '{print $1}'):6060"
echo "   3. (Optional) Setup HTTPS with nginx/Caddy"
echo ""

# Health check
sleep 3
if curl -f http://localhost:6060/ > /dev/null 2>&1; then
    log "✅ Health check passed!"
    curl -s http://localhost:6060/
else
    warn "⚠️  Health check failed. Check logs for errors."
fi
