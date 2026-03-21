# YTAudio Deployment Guide

Complete guide for deploying YTAudio backend with automated GitHub-based updates.

## 📋 Table of Contents

1. [Quick Start](#quick-start)
2. [Setup Methods](#setup-methods)
3. [GitHub Actions CI/CD](#github-actions-cicd)
4. [Update Workflows](#update-workflows)
5. [Rollback](#rollback)
6. [Monitoring](#monitoring)

---

## Quick Start

### 1. Push to GitHub

```bash
cd ViralMusic
git init
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/YOUR_USERNAME/ViralMusic.git
git push -u origin main
```

### 2. Setup Server (One-time)

```bash
# SSH into your server
ssh user@your-server

# Download and run installer
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/ViralMusic/main/scripts/install.sh | bash -s https://github.com/YOUR_USERNAME/ViralMusic.git main
```

Or manually:
```bash
git clone https://github.com/YOUR_USERNAME/ViralMusic.git ~/ViralMusic
cd ~/ViralMusic
chmod +x scripts/install.sh
./scripts/install.sh
```

### 3. Configure GitHub Secrets

Go to **Settings → Secrets → Actions** in your GitHub repo and add:

| Secret Name | Value | Description |
|-------------|-------|-------------|
| `SERVER_HOST` | `123.456.789.0` | Your server IP |
| `SERVER_USER` | `ubuntu` | SSH username |
| `SSH_PRIVATE_KEY` | `-----BEGIN...` | Your SSH private key |
| `SERVER_PORT` | `22` | SSH port (optional) |

---

## Setup Methods

### Method 1: Docker (Recommended)

**Pros:** Isolated, consistent, easy updates, auto-restart  
**Cons:** Slightly more resource usage

```bash
# During install.sh, choose option 1
./scripts/install.sh
# → Select: 1) Docker

# Updates are automatic or manual:
~/update-viralmusic.sh
# Or push to GitHub (if Actions configured)
```

**Auto-updates with Watchtower:**
```bash
cd ~/ViralMusic
docker-compose --profile auto-update up -d
# Checks for new images every 5 minutes
```

### Method 2: Supervisor

**Pros:** Simple, good for single-server  
**Cons:** Less isolation than Docker

```bash
# During install.sh, choose option 2
./scripts/install.sh
# → Select: 2) Supervisor

# Manual update:
~/update-viralmusic.sh
```

### Method 3: Systemd

**Pros:** Native Linux integration, logging  
**Cons:** Linux only

```bash
# During install.sh, choose option 3
./scripts/install.sh
# → Select: 3) Systemd

# Manual update:
~/update-viralmusic.sh
```

---

## GitHub Actions CI/CD

### Automated Deployment Flow

```
1. Push code to main branch
        ↓
2. GitHub Actions triggers
        ↓
3. Run tests (lint, basic checks)
        ↓
4. SSH into server
        ↓
5. Pull latest code
        ↓
6. Update dependencies
        ↓
7. Restart service
        ↓
8. Health check
        ↓
9. Deployment complete! 🎉
```

### Workflows Explained

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `deploy.yml` | Push to main | Standard deployment (Python) |
| `docker-deploy.yml` | Push to main | Docker build + deploy |
| `release.yml` | Tag push (v*) | Create GitHub releases |

### Docker Build & Push

When you push to `main`, GitHub Actions:
1. Builds Docker image for AMD64 and ARM64
2. Pushes to GitHub Container Registry (ghcr.io)
3. Tags with branch name and SHA
4. Deploys to your server

**Tag format:** `ghcr.io/USER/REPO/viralmusic-backend:main`

---

## Update Workflows

### Option A: Git Push (Automatic)

```bash
# Make changes locally
vim backend/server.py

# Commit and push
git add .
git commit -m "Add new feature"
git push origin main

# GitHub Actions deploys automatically!
# Check progress: https://github.com/YOUR_USERNAME/ViralMusic/actions
```

### Option B: Manual Update (Server-side)

```bash
# SSH to server
ssh user@your-server

# Run update script (created by install.sh)
~/update-viralmusic.sh

# Or manually:
cd ~/ViralMusic
git pull
# ... restart service
```

### Option C: Docker Pull (No rebuild)

```bash
# On server
cd ~/ViralMusic
docker-compose pull  # Get latest image
docker-compose up -d
```

### Option D: Automatic Updates (Watchtower)

Enable Watchtower for fully automatic updates:

```bash
cd ~/ViralMusic
docker-compose --profile auto-update up -d

# Now any new image pushed to ghcr.io will be deployed automatically
# within 5 minutes (configured interval)
```

---

## Rollback

If a deployment breaks, rollback quickly:

### Docker Rollback

```bash
cd ~/ViralMusic

# List available images
docker images ghcr.io/YOUR_USERNAME/ViralMusic/viralmusic-backend

# Rollback to previous image
docker-compose down
docker tag ghcr.io/...:previous-tag ghcr.io/...:main
docker-compose up -d

# Or use backup
cp -r ~/backups/viralmusic-YYYYMMDD-HHMMSS/backend/* ./backend/
~/update-viralmusic.sh
```

### Python Rollback

```bash
# Restore from backup
cp -r ~/backups/viralmusic-YYYYMMDD-HHMMSS/backend/* ~/ViralMusic/backend/

# Restart
sudo systemctl restart viralmusic  # or supervisorctl
```

### Git Rollback

```bash
cd ~/ViralMusic

# View history
git log --oneline -10

# Rollback to specific commit
git reset --hard abc1234

# Restart service
~/update-viralmusic.sh
```

---

## Monitoring

### Check Deployment Status

```bash
# GitHub Actions status
# Visit: https://github.com/YOUR_USERNAME/ViralMusic/actions

# Server health
curl http://your-server:6060/

# Service status (systemd)
sudo systemctl status viralmusic

# Service status (supervisor)
sudo supervisorctl status viralmusic

# Docker status
docker-compose ps
docker-compose logs -f
```

### View Logs

**Docker:**
```bash
docker-compose logs -f --tail 100
```

**Systemd:**
```bash
sudo journalctl -u viralmusic -f
```

**Supervisor:**
```bash
sudo tail -f /var/log/viralmusic.out.log
sudo tail -f /var/log/viralmusic.err.log
```

**GitHub Actions:**
- Visit: `https://github.com/YOUR_USERNAME/ViralMusic/actions`
- Click on latest workflow run
- View real-time logs

---

## Advanced Configuration

### Environment Variables

Create `.env` file in `backend/` or set in service config:

```bash
PORT=6060              # Server port
HOST=0.0.0.0           # Bind address
PYTHONUNBUFFERED=1     # Unbuffered output
```

### HTTPS with Caddy (Easy)

```bash
# Install Caddy
sudo apt install caddy

# Create Caddyfile
sudo tee /etc/caddy/Caddyfile << EOF
viralmusic.yourdomain.com {
    reverse_proxy localhost:6060
}
EOF

# Reload Caddy
sudo systemctl reload caddy
```

### HTTPS with nginx

```nginx
server {
    listen 443 ssl http2;
    server_name viralmusic.yourdomain.com;
    
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    
    location / {
        proxy_pass http://localhost:6060;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 86400;
    }
}
```

---

## Troubleshooting

### Deployment Failed

```bash
# Check GitHub Actions logs
# Visit: https://github.com/YOUR_USERNAME/ViralMusic/actions

# Check server logs
ssh user@server
sudo journalctl -u viralmusic -n 100

# Or for Docker
docker-compose logs
```

### SSH Connection Failed

```bash
# Test SSH key
cat ~/.ssh/id_rsa.pub
# Add to server's ~/.ssh/authorized_keys

# Test connection
ssh -i ~/.ssh/id_rsa user@server

# Check GitHub secret is correct
cat ~/.ssh/id_rsa | base64 -w0  # Copy this to GitHub secret
```

### Permission Denied

```bash
# Fix file permissions
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub

# Fix sudo (if needed)
sudo visudo
# Add: youruser ALL=(ALL) NOPASSWD: /bin/systemctl restart viralmusic
```

---

## Summary Commands

| Task | Command |
|------|---------|
| **Deploy** | `git push origin main` |
| **Manual update** | `~/update-viralmusic.sh` |
| **View logs** | `docker-compose logs -f` or `journalctl -u viralmusic -f` |
| **Restart** | `docker-compose restart` or `sudo systemctl restart viralmusic` |
| **Health check** | `curl http://localhost:6060/` |
| **Rollback** | Restore from `~/backups/` |

---

## Need Help?

1. Check [GitHub Actions logs](https://github.com/YOUR_USERNAME/ViralMusic/actions)
2. Check server logs: `sudo journalctl -u viralmusic -f`
3. Check [Issues](../../issues) for common problems
