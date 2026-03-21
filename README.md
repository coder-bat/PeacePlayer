# YT Audio Extraction System

A personal research project for audio extraction and playback from YouTube Music.

**Status:** Personal use only - NOT FOR DISTRIBUTION

## Quick Start (Choose Your Path)

### Option 1: Guest Mode (Fastest - No Login Required)
```bash
cd ViralMusic
make setup    # Install Python dependencies
make backend  # Start server (no auth needed!)
```

**Guest mode includes:**
- ✅ Search any song on YouTube Music
- ✅ Stream audio immediately
- ✅ Download to local library
- ✅ Get lyrics
- ✅ Radio/autoplay based on songs

### Option 2: Authenticated Mode (Full Features)
```bash
cd ViralMusic
make setup    # Install Python dependencies
make auth     # Authenticate with Google (optional)
make backend  # Start server
```

**Authenticated mode adds:**
- ✅ Access your liked songs
- ✅ Access your playlists
- ✅ Better personalized recommendations
- ✅ Upload music to your library

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        iOS Client (Swift)                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │   Search UI  │  │ Audio Player │  │  Download Manager    │  │
│  │  (SwiftUI)   │  │ (AVPlayer)   │  │  (Background tasks)  │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │ WiFi / Localhost
┌─────────────────────────────┼──────────────────────────────────┐
│                     Python Backend (macOS/Linux/RPi)           │
│  ┌──────────────┐  ┌────────┴───────┐  ┌──────────────────┐   │
│  │  ytmusicapi  │  │   yt-dlp       │  │   FFmpeg         │   │
│  │  (Search/    │  │   (Extraction) │  │   (Transcoding)  │   │
│  │   Metadata)  │  │                │  │                  │   │
│  └──────────────┘  └────────────────┘  └──────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### Backend (`/backend`)
- Python Flask/FastAPI server
- YouTube Music API integration (ytmusicapi)
- Audio extraction (yt-dlp + FFmpeg)
- Local file serving
- **Works with or without authentication**

### iOS Client (`/ios`)
- SwiftUI interface
- AVPlayer for audio playback
- Background audio support
- Local library management

## Feature Comparison

| Feature | Guest Mode | Authenticated |
|---------|-----------|---------------|
| Search songs | ✅ | ✅ |
| Stream audio | ✅ | ✅ |
| Download tracks | ✅ | ✅ |
| View lyrics | ✅ | ✅ |
| Radio/autoplay | ✅ | ✅ |
| Liked songs | ❌ | ✅ |
| Your playlists | ❌ | ✅ |
| Uploads | ❌ | ✅ |
| Personalized recs | ❌ | ✅ |

## Setup Guide

### 1. Backend Setup

```bash
# Clone/navigate to project
cd ViralMusic

# Install Python dependencies
make setup

# (Optional) Add authentication for extra features
# Skip this if you just want to try guest mode
make auth

# Start the server
make backend
```

The server will start on `http://0.0.0.0:8080`.

### 2. iOS Setup

```bash
# Show your Mac's IP address
make ip

# Open Xcode project
make ios
```

In Xcode:
1. Edit `Sources/APIService.swift` - update the IP address
2. Select your development team in project settings
3. Connect your iOS device
4. Build and run (Cmd+R)

### 3. Using the App

Once both backend and iOS app are running:

1. **Search**: Type a song/artist in the Search tab
2. **Stream**: Tap the play button ▶️ to stream immediately
3. **Download**: Tap the download button ⬇️ to save locally
4. **Library**: View downloaded tracks in Library tab
5. **Background**: Audio continues playing when app is backgrounded

## Authentication (Optional)

To access your personal library and playlists:

1. Run `make auth`
2. Choose option 1 (Browser Headers)
3. Follow the instructions to copy your cookie from music.youtube.com
4. Paste when prompted
5. Restart the server

Your credentials are saved to `oauth.json` and used for future runs.

**To remove authentication:**
```bash
rm backend/oauth.json
# Restart server to use guest mode
```

## Troubleshooting

### "Cannot connect to server"
- Check backend is running: `curl http://localhost:8080/`
- Verify IP address in APIService.swift matches your Mac's IP
- Ensure iPhone and Mac are on same WiFi network

### "No audio in background"
- Check Info.plist has `UIBackgroundModes` with `audio`
- Ensure you accepted microphone/background audio permissions

### Guest mode works but auth fails
- Try `make auth` again with fresh browser cookies
- Check that you're logged into music.youtube.com
- Clear browser cookies and try again

## Documentation

- [Architecture](docs/ARCHITECTURE.md) - System design details
- [API Reference](docs/API_REFERENCE.md) - Backend endpoints
- [Setup Guide](docs/SETUP_GUIDE.md) - Detailed installation
- [Technical Notes](docs/TECHNICAL_NOTES.md) - Implementation details

## Commands Reference

```bash
make setup      # Install Python dependencies
make auth       # (Optional) Authenticate with Google
make backend    # Start backend server
make ios        # Open iOS project in Xcode
make ip         # Show your Mac's IP address
make clean      # Clean temporary files
make install    # Same as setup
```
