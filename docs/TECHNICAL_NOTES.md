# Technical Implementation Notes

## Audio Format Details

### YouTube Audio Streams

YouTube serves audio in these formats (itag codes):

| itag | Codec | Bitrate | Container | Quality |
|------|-------|---------|-----------|---------|
| 251 | Opus | 160 kbps | WebM | Best |
| 140 | AAC | 128 kbps | M4A | Good (iOS native) |
| 250 | Opus | 70 kbps | WebM | Medium |
| 249 | Opus | 50 kbps | WebM | Low |

### Conversion Pipeline

```
YouTube Stream (WebM/Opus) 
    ↓
Download to temp file
    ↓
FFmpeg transcoding:
    -vn (no video)
    -c:a aac 
    -b:a 128k
    -ar 44100
    -metadata (title, artist, album)
    ↓
M4A output file (iOS compatible)
```

## Stream URL Lifecycle

1. **Extraction**: ytmusicapi fetches song data including `streamingData`
2. **URL Creation**: Direct signed URLs to GoogleVideo CDN
3. **Expiration**: URLs valid for ~6 hours
4. **Playback**: iOS AVPlayer streams directly from URL
5. **Seeking**: HTTP Range requests supported

## Authentication Flow

### ytmusicapi OAuth

```
1. Run setup_oauth.py
2. Open browser to Google OAuth consent
3. User logs in and grants permissions
4. Authorization code returned
5. Exchange for refresh + access tokens
6. Save to oauth.json
7. Subsequent requests use access token
8. Auto-refresh when expired
```

### No Authentication (Guest Mode)

- Search works without auth
- Stream URLs accessible
- Some tracks may be restricted
- No access to personal library/recommendations

## Network Protocol

### Request Flow

```
iOS Client (Swift)
    ↓ HTTP/1.1 or HTTP/2
Python Backend (FastAPI)
    ↓ HTTPS (external)
YouTube Music API
    ↓ Internal protobuf
YouTube Servers
```

### CORS Handling

FastAPI middleware allows all origins for local development:

```python
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

Production would restrict to specific origins.

## iOS Audio Architecture

### AVAudioSession Configuration

```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
try session.setActive(true)
```

This enables:
- Background audio playback
- Control Center integration
- AirPlay support
- Interruption handling

### Remote Control Events

Implemented via `MPRemoteCommandCenter`:
- Play/Pause
- Seek (changePlaybackPosition)
- Now Playing info display

### Audio Pipeline

```
Remote URL (HTTP)
    ↓
AVPlayerItem
    ↓
AVPlayer (manages playback)
    ↓
AVAudioSession (output)
    ↓
Speaker/Headphones/AirPlay
```

## Memory Management

### Backend

- Streaming downloads: Chunked (8KB chunks)
- Temp files: Cleaned up after conversion
- Concurrent downloads: Unlimited (personal use)

### iOS

- Images: AsyncImage with caching
- Audio: No local caching (stream only)
- Memory pressure: AVPlayer handles buffering

## Error Handling

### Backend Errors

| Error | Cause | Resolution |
|-------|-------|------------|
| 404 | Video not found/private | Try different track |
| 403 | Age restricted / Premium | Skip track |
| 500 | Extraction failed | Retry or different track |
| Timeout | Slow network | Increase timeout |

### iOS Errors

| Error | Cause | Resolution |
|-------|-------|------------|
| Network | Backend unreachable | Check connection |
| Decoding | Invalid stream | Re-fetch URL |
| Playback | Codec issue | Convert to AAC |

## Performance Optimizations

### Backend

1. **Lazy loading**: Only extract when requested
2. **Format selection**: Prefer AAC (140) over Opus (251) to avoid conversion
3. **Single-threaded**: Sequential processing for stability

### iOS

1. **Debounced search**: 300ms delay on typing
2. **Image caching**: URLCache for thumbnails
3. **Lazy views**: SwiftUI lazy loading for lists

## Security Considerations

### OAuth Token Storage

- Stored in plain JSON file
- No encryption (personal use assumption)
- File permissions: User read-only

### Network Security

- Local network only (no TLS)
- No authentication on API endpoints
- CORS open for development

### iOS Transport Security

```xml
<key>NSAllowsArbitraryLoads</key>
<true/>
```

Allows HTTP (not HTTPS) connections. Acceptable for local network.

## Extending the System

### Adding Features

1. **Lyrics display**: Endpoint exists, UI needed
2. **Radio mode**: `get_watch_playlist` implemented
3. **Playlists**: Store in TinyDB
4. **Search history**: Core Data or UserDefaults

### Alternative Backends

- **Docker**: Containerize Python backend
- **Raspberry Pi**: Run 24/7 low-power server
- **NAS**: Store library on network storage

### iOS Enhancements

- **Widgets**: Now playing widget
- **Shortcuts**: Siri integration
- **CarPlay**: Audio app extension
- **Apple Watch**: Remote control

## Debugging

### Backend Logging

Enable debug logging:

```python
import logging
logging.basicConfig(level=logging.DEBUG)
```

### iOS Network Debugging

Use Instruments or Console app:
- Check HTTP requests
- Monitor audio session state
- View memory usage

### Common Issues

1. **Streams cut out**: URL expired, need refresh
2. **Slow startup**: Thumbnail loading, implement placeholder
3. **High CPU**: Conversion happening, pre-convert popular tracks
