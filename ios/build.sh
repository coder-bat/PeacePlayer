#!/bin/bash
set -e

echo "🎵 YTAudioPlayer CLI Build"
echo "=========================="
echo ""

# 1. Check/Install xcodegen
if ! command -v xcodegen &> /dev/null; then
    echo "📦 Installing xcodegen..."
    if command -v brew &> /dev/null; then
        brew install xcodegen
    else
        echo "❌ Please install Homebrew: https://brew.sh"
        exit 1
    fi
fi

# 2. Backup old project if exists
if [ -d "YTAudioPlayer.xcodeproj" ]; then
    echo "💾 Backing up old project..."
    mv YTAudioPlayer.xcodeproj YTAudioPlayer.xcodeproj.backup.$(date +%s)
fi

# 3. Remove nested duplicate folders
rm -rf YTAudioPlayer/YTAudioPlayer 2>/dev/null || true

# 4. Generate fresh project
echo "🔧 Generating Xcode project..."
xcodegen generate

# 5. Verify source files exist
echo ""
echo "📋 Source files:"
find YTAudioPlayer -name "*.swift" -type f 2>/dev/null | while read f; do
    echo "  ✓ $(basename $f)"
done

# 6. Build
echo ""
echo "🔨 Building..."
xcodebuild \
    -project YTAudioPlayer.xcodeproj \
    -scheme YTAudioPlayer \
    -destination 'generic/platform=iOS' \
    -configuration Debug \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_ALLOWED=NO \
    build

echo ""
echo "✅ BUILD SUCCESSFUL!"
echo ""
echo "Next steps:"
echo "1. Update IP in YTAudioPlayer/Sources/APIService.swift (line 18)"
echo "   Find your IP: make ip"
echo "2. Open YTAudioPlayer.xcodeproj in Xcode"
echo "3. Select your device and run (Cmd+R)"
echo ""
echo "Or run on device from CLI:"
echo "   xcodebuild -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS,name=YOUR_DEVICE_NAME' build"
