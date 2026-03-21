# Password Authentication Guide

This guide covers deploying ViralMusic using SSH password authentication instead of SSH keys.

⚠️ **Security Warning**: Password authentication is less secure than SSH keys. Consider this for testing/development only, or use with strong passwords and additional security measures.

---

## Why Passwords Are Less Secure

| SSH Keys | Passwords |
|----------|-----------|
| Cryptographically secure | Can be brute-forced |
| Never transmitted after setup | Sent with each connection |
| Easy to revoke (delete key) | Hard to change (must update all clients) |
| No user interaction needed | May prompt for 2FA/code |
| Industry standard | Discouraged for automation |

---

## Quick Setup (Password Auth)

### Step 1: Enable Password Auth on Server

SSH into your server and run:

```bash
# Download and run the enable script
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/ViralMusic/main/scripts/enable-password-auth.sh | sudo bash

# Or manually:
sudo nano /etc/ssh/sshd_config

# Set these values:
PasswordAuthentication yes
ChallengeResponseAuthentication yes

# Restart SSH
sudo systemctl restart sshd
```

### Step 2: Configure GitHub Secrets

Go to **Settings → Secrets → Actions** and add:

```
SERVER_HOST       → 123.456.789.0
SERVER_USER       → ubuntu
SERVER_PASSWORD   → your-strong-password
SERVER_PORT       → 22
```

### Step 3: Use Password Workflow

The repository includes password-specific workflows:

```bash
# Switch to password workflows (if not already)
mv .github/workflows/deploy.yml .github/workflows/deploy-ssh.yml
mv .github/workflows/deploy-password.yml .github/workflows/deploy.yml

git add .github/workflows/
git commit -m "Use password authentication"
git push origin main
```

Or use the setup script:

```bash
./scripts/setup-github-password.sh
```

---

## Security Hardening (If Using Passwords)

### 1. Use a Strong Password

```bash
# On server, set a strong password
sudo passwd your-user

# Requirements:
# - Minimum 16 characters
# - Mix of uppercase, lowercase, numbers, symbols
# - No dictionary words
# - Unique (not used elsewhere)
```

### 2. Change SSH Port

```bash
# Edit SSH config
sudo nano /etc/ssh/sshd_config

# Change port
Port 2222

# Restart
sudo systemctl restart sshd

# Update GitHub secret: SERVER_PORT → 2222
```

### 3. Install fail2ban

```bash
# Install
sudo apt install fail2ban

# Configure
sudo tee /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF

# Start
sudo systemctl restart fail2ban
```

### 4. Limit SSH to Specific IP (Optional)

```bash
# Allow only GitHub Actions IPs (approximate ranges)
# Note: GitHub IPs change, use with caution
sudo ufw allow from 140.82.112.0/20 to any port 22
```

### 5. Use Non-Root User

```bash
# Create deploy user
sudo useradd -m deploy
sudo usermod -aG sudo deploy
sudo passwd deploy

# Set up sudo without password for specific commands
sudo visudo
# Add: deploy ALL=(ALL) NOPASSWD: /bin/systemctl restart viralmusic, /usr/bin/supervisorctl restart viralmusic

# Use 'deploy' user in GitHub secrets instead of root
```

---

## Migration to SSH Keys (Recommended)

Ready to upgrade to SSH keys? Run the migration script:

```bash
# On your local machine
./scripts/migrate-to-ssh-keys.sh
```

This will:
1. Generate a new SSH key pair
2. Copy public key to server
3. Update GitHub secrets
4. Switch to SSH workflow
5. Optionally disable password auth

---

## Troubleshooting

### "Permission denied (password)"

```bash
# Check if password auth is enabled
grep PasswordAuthentication /etc/ssh/sshd_config
# Should show: PasswordAuthentication yes

# Check if user exists and has password
grep your-user /etc/passwd
sudo passwd your-user  # Set password

# Check SSH logs
sudo tail -f /var/log/auth.log
```

### "Connection timed out"

```bash
# Check if SSH is running
sudo systemctl status sshd

# Check firewall
sudo ufw status
sudo ufw allow 22/tcp

# Check port
grep ^Port /etc/ssh/sshd_config
```

### Workflow fails but manual SSH works

```bash
# GitHub Actions might need specific SSH settings
# Add to workflow:
- name: Setup SSH
  run: |
    mkdir -p ~/.ssh
    echo "Host *" >> ~/.ssh/config
    echo "  StrictHostKeyChecking no" >> ~/.ssh/config
    echo "  UserKnownHostsFile=/dev/null" >> ~/.ssh/config
```

---

## Workflow Files

### Password-Based Deployment

File: `.github/workflows/deploy.yml` (password version)

```yaml
- name: Deploy via SSH with password
  uses: appleboy/ssh-action@v1.0.3
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    password: ${{ secrets.SERVER_PASSWORD }}  # <-- Uses password
    port: ${{ secrets.SERVER_PORT || '22' }}
    script: |
      # ... deployment commands
```

### Key-Based Deployment

File: `.github/workflows/deploy-ssh.yml`

```yaml
- name: Deploy via SSH with key
  uses: appleboy/ssh-action@v1.0.3
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}  # <-- Uses SSH key
    port: ${{ secrets.SERVER_PORT || '22' }}
    script: |
      # ... deployment commands
```

---

## Summary

| Method | Security | Ease of Setup | Recommendation |
|--------|----------|---------------|----------------|
| **SSH Keys** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ✅ **Production** |
| **Password + Hardening** | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⚠️ Development |
| **Password (default)** | ⭐⭐ | ⭐⭐⭐⭐⭐ | ❌ Not recommended |

**Recommendation**: Start with password auth for quick testing, then migrate to SSH keys for long-term use.
