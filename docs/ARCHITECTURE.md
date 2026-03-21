# System Architecture

## Overview

This system enables personal audio extraction and playback from YouTube Music sources through a client-server architecture.

## Design Principles

1. **Separation of Concerns**: Python handles extraction/complexity, iOS handles playback/UI
2. **Local-First**: All processing happens on local network, no cloud dependencies
3. **Modular**: Components can be replaced/swapped independently

## Data Flow

### Search Flow
```
iOS Search Query → HTTP POST /search → ytmusicapi.search() → YouTube Music API
                                                      ↓
iOS Display Results ← JSON Track Metadata ← Response Processing
```

### Streaming Flow
```
iOS Play Request → HTTP GET /stream/{id} → ytmusicapi.get_song()
                                                 ↓
                                    Extract adaptiveFormats
                                                 ↓
iOS AVPlayer ← Direct Stream URL ← Best Audio Format Selected
```

### Download Flow
```
iOS Download Request → HTTP POST /download → yt-dlp extraction
                                                   ↓
                                    FFmpeg transcoding to M4A
                                                   ↓
iOS Play Local ← HTTP GET /local-play/{file} ← File Saved Locally
```

## Technical Decisions

### Why Python Backend?
- ytmusicapi and yt-dlp are Python-native
- Easier to maintain extraction logic outside iOS sandbox
- Can run on Raspberry Pi, NAS, or Mac always-on

### Why M4A Output?
- Native iOS support (no third-party codecs needed)
- AAC codec is efficient and compatible
- Metadata embedding (ID3 tags) works well

### Network Protocol
- HTTP/REST for simplicity
- Local network only (no TLS needed for LAN)
- Stream URLs passed directly to AVPlayer (efficient)

## Background Audio Strategy

iOS AVAudioSession configured with:
- Category: `.playback`
- Mode: `.default`
- Options: `[.allowAirPlay]`

Remote transport controls implemented via MPNowPlayingInfoCenter for Control Center integration.

## Storage

### Backend
- Downloads stored in `~/Music/YTAudio/` by default
- Organized by filename pattern: `{Title} - {Artist}.m4a`
- No database - filesystem is source of truth

### iOS
- No local storage (streaming only)
- Metadata cached in memory during session

## Security Considerations

- OAuth credentials stored only on backend
- No API keys in iOS client
- Local network isolation
- No external network calls from iOS (except to backend)
