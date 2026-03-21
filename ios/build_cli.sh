#!/bin/bash
# Build YTAudioPlayer using Xcode CLI

set -e

echo "YTAudioPlayer CLI Build"
echo "======================="
echo ""

# Check for xcodegen
if ! command -v xcodegen &> /dev/null; then
    echo "❌ xcodegen not found. Installing..."
    if command -v brew &> /dev/null; then
        brew install xcodegen
    else
        echo "Please install Homebrew first: https://brew.sh"
        exit 1
    fi
fi

# Generate project
echo "📋 Generating Xcode project..."
xcodegen generate

# Check if generation succeeded
if [ ! -d "YTAudioPlayer.xcodeproj" ]; then
    echo "❌ Failed to generate project"
    exit 1
fi

echo "✅ Project generated"
echo ""

# Find available destinations
echo "📱 Available build destinations:"
echo ""
xcodebuild -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -showdestinations | grep "platform:iOS" | head -5
echo ""

# Try to build for generic iOS device (no signing required for this step)
echo "🔨 Building for generic iOS device (testing compilation)..."
xcodebuild \
    -project YTAudioPlayer.xcodeproj \
    -scheme YTAudioPlayer \
    -destination 'generic/platform=iOS' \
    -configuration Debug \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

echo ""
echo "✅ Build succeeded!"
echo ""
echo "To build for your device:"
echo "1. Open YTAudioPlayer.xcodeproj in Xcode"
echo "2. Select your team in Signing & Capabilities"
echo "3. Or run:"
echo "   xcodebuild -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS,name=YOUR_DEVICE_NAME' build"
