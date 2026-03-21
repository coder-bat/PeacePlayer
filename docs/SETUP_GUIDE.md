# Setup Guide

## Prerequisites

- macOS with Xcode 14+
- Python 3.9+
- iOS device (not simulator, for network access)
- Local WiFi network

## Backend Setup

### 1. Install Python Dependencies

```bash
cd YTAudioSystem/backend
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. Authenticate with YouTube Music

Run the setup script to generate OAuth credentials:

```bash
python setup_oauth.py
```

This will:
- Open a browser for Google authentication
- Save credentials to `oauth.json`
- Enable personalized search and recommendations

**Note:** Keep `oauth.json` private - it contains your authentication tokens.

### 3. Start the Server

```bash
python server.py
```

Server will start on `http://0.0.0.0:8080`

To run on a specific IP (for device testing):

```bash
HOST=192.168.1.100 python server.py
```

## iOS Setup

### 1. Update Backend IP

Edit `ios/YTAudioPlayer/Sources/APIService.swift`:

```swift
private let baseURL = "http://x.x.x.x:8080"
```

Replace `YOUR_MAC_IP` with your Mac's local IP (find it in System Preferences > Network).

### 2. Open in Xcode

```bash
cd YTAudioSystem/ios
open YTAudioPlayer.xcodeproj
```

### 3. Configure Signing

- Select project in Xcode
- Choose your development team
- Set bundle identifier (e.g., `com.yourname.ytaudioplayer`)

### 4. Build and Run

- Select your iOS device (not simulator)
- Press Run
- Accept trust prompt on device

## Network Configuration

### Firewall

Allow port 8080 through macOS Firewall:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add $(which python)
```

Or disable firewall temporarily for testing:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off
```

### Router

Ensure both devices are on the same WiFi network. No port forwarding needed for local LAN.

## Troubleshooting

### "Cannot connect to server"

1. Verify backend is running: `curl http://localhost:8080/`
2. Check IP address is correct in APIService.swift
3. Ensure devices are on same network
4. Try accessing from iOS Safari: `http://YOUR_MAC_IP:8080/`

### "No audio in background"

1. Check Info.plist has `UIBackgroundModes` with `audio`
2. Ensure audio session is configured: `AVAudioSession.Category.playback`
3. Check Control Center shows the track

### OAuth Errors

If `oauth.json` expires or fails:

```bash
rm oauth.json
python setup_oauth.py
```

### High Memory Usage

Downloads are processed in memory before saving. For long tracks, this may use significant RAM. The Python backend streams to disk to minimize this.

## Usage Flow

1. **Search**: Enter song/artist in Search tab
2. **Stream**: Tap play button to stream immediately
3. **Download**: Tap download button to save to backend library
4. **Library**: View downloaded tracks in Library tab
5. **Play Local**: Tap play on library tracks (streams from backend storage)

## File Locations

### Backend
- Downloads: `~/Music/YTAudio/`
- OAuth: `backend/oauth.json`
- Logs: Console output

### iOS
- No local file storage (streaming only)
- Settings: Standard iOS app storage
