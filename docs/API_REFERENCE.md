# Backend API Reference

## Endpoints

### POST /search
Search for tracks on YouTube Music.

**Request:**
```json
{
  "query": "search terms",
  "limit": 20
}
```

**Response:**
```json
{
  "results": [
    {
      "video_id": "dQw4w9WgXcQ",
      "title": "Never Gonna Give You Up",
      "artists": ["Rick Astley"],
      "album": "Whenever You Need Somebody",
      "duration_seconds": 213,
      "thumbnails": [
        {
          "url": "https://...",
          "width": 640,
          "height": 480
        }
      ],
      "is_explicit": false,
      "video_type": "MUSIC_VIDEO_TYPE_ATV"
    }
  ]
}
```

### GET /stream/{video_id}
Get streaming URL for immediate playback.

**Response:**
```json
{
  "stream_url": "https://rr1---sn-...googlevideo.com/...",
  "mime_type": "audio/webm; codecs=opus",
  "bitrate": 160000
}
```

**Notes:**
- URL expires after ~6 hours
- Returns best quality audio format available
- Supports partial content (HTTP 206) for seeking

### POST /download
Download and convert track to local M4A file.

**Request:**
```json
{
  "video_id": "dQw4w9WgXcQ",
  "title": "Never Gonna Give You Up",
  "artists": ["Rick Astley"],
  "album": "Whenever You Need Somebody"
}
```

**Response:**
```json
{
  "status": "completed",
  "file_path": "/Users/.../Music/YTAudio/Never Gonna Give You Up - Rick Astley.m4a"
}
```

**Process:**
1. Extracts audio stream URL using yt-dlp
2. Downloads stream to temp file
3. Converts to AAC 128kbps M4A using FFmpeg
4. Embeds metadata (title, artist, album)
5. Moves to library directory
6. Returns final path

### GET /local-play/{filename}
Stream local file to iOS client.

**Headers:**
- Accept-Ranges: bytes (supports seeking)
- Content-Type: audio/mp4

**Query Parameters:**
- `filename`: URL-encoded filename from /library listing

### GET /library
List all downloaded tracks.

**Response:**
```json
{
  "tracks": [
    {
      "filename": "Song Title - Artist Name.m4a",
      "size": 4257024,
      "modified": 1704067200.0
    }
  ]
}
```

## Error Responses

All errors return JSON with detail message:

```json
{
  "detail": "Error description"
}
```

Common status codes:
- `404`: Track/stream not found
- `500`: Processing error (extraction failed, conversion error)
- `422`: Invalid request parameters

## Rate Limiting

No explicit rate limiting implemented (personal use).
YouTube may throttle requests if excessive.

Recommended client behavior:
- Debounce search requests (300ms)
- Don't retry failed downloads immediately
- Cache search results client-side
