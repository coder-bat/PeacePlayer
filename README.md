# PeacePlayer

A personal iOS music player with a clean, native SwiftUI interface.

**Personal use only — not for distribution.**

---

## How It Works

PeacePlayer has two parts:

- **iOS app** — SwiftUI client running on your iPhone
- **Python backend** — runs on your Mac, handles music search, streaming, and audio extraction

The iPhone connects to your Mac over your local network (WiFi or Tailscale).

---

## Quick Start

### 1. Start the backend

```bash
make setup    # First time only — installs Python dependencies
make backend  # Start the server on port 8181
```

### 2. (Optional) Authenticate for full library access

```bash
make auth     # Follow prompts to connect your Google account
```

This unlocks your liked songs, playlists, and personalized recommendations. Without it, search and streaming still work.

### 3. Configure the iOS app

Edit `ios/Sources/APIService.swift` and set your Mac's hostname or IP:

```swift
return "http://YOUR_MACHINE_HOSTNAME:8181"
```

To find your IP:
```bash
make ip
```

### 4. Build and run

Open the Xcode project:
```bash
make ios
```

In Xcode:
1. Set your Development Team (Signing & Capabilities)
2. Select your iPhone as the target device
3. Build and run (Cmd+R)

---

## Features

| Feature | Guest | Authenticated |
|---------|-------|---------------|
| Search songs | ✅ | ✅ |
| Stream audio | ✅ | ✅ |
| Download tracks | ✅ | ✅ |
| Lyrics | ✅ | ✅ |
| Radio / autoplay | ✅ | ✅ |
| Liked songs | ❌ | ✅ |
| Your playlists | ❌ | ✅ |
| Personalized recommendations | ❌ | ✅ |

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  iOS App (Swift)                     │
│  SwiftUI · AVPlayer · Core Data · Background Audio  │
└────────────────────────┬────────────────────────────┘
                         │ HTTP (WiFi / Tailscale)
┌────────────────────────┴────────────────────────────┐
│              Python Backend (macOS)                  │
│  FastAPI · ytmusicapi · yt-dlp · FFmpeg             │
└─────────────────────────────────────────────────────┘
```

---

## Makefile Commands

```bash
make setup        # Install Python dependencies
make backend      # Start backend server (port 8181)
make dev          # Start with auto-reload (development)
make auth         # Authenticate with Google (optional)
make ios          # Open Xcode project
make ip           # Show your Mac's local IP address
make clean        # Remove cached/temp files
make distclean    # Full reset (removes venv + oauth)
```

---

## Troubleshooting

**"Cannot connect to server"**
- Confirm the backend is running: `curl http://localhost:8181/`
- Check the IP/hostname in `APIService.swift` matches your Mac
- Make sure iPhone and Mac are on the same network, or both on Tailscale

**No audio in background**
- Info.plist must have `UIBackgroundModes` → `audio`
- Accept background audio permissions when prompted

**Auth fails**
- Re-run `make auth` 
- Delete `backend/oauth.json` to reset to guest mode

---

## Docs

- [Architecture](docs/ARCHITECTURE.md)
- [API Reference](docs/API_REFERENCE.md)
- [Setup Guide](docs/SETUP_GUIDE.md)
- [Technical Notes](docs/TECHNICAL_NOTES.md)
