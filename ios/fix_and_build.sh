#!/bin/bash
# Fix Info.plist duplication and build using existing project

set -e

echo "YTAudioPlayer Build Fix"
echo "======================="
echo ""

# Check if project exists
if [ ! -d "YTAudioPlayer.xcodeproj" ]; then
    echo "❌ YTAudioPlayer.xcodeproj not found"
    echo "Please create the project in Xcode first, then run this script"
    exit 1
fi

echo "🔧 Checking project structure..."

# Find Info.plist references
INFO_PLIST_PATH="YTAudioPlayer/Info.plist"

if [ ! -f "$INFO_PLIST_PATH" ]; then
    echo "⚠️  Info.plist not found at expected location"
    echo "Creating minimal Info.plist..."
    
    mkdir -p YTAudioPlayer
    cat > "$INFO_PLIST_PATH" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <true/>
    </dict>
    <key>UIApplicationSupportsIndirectInputEvents</key>
    <true/>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>armv7</string>
    </array>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
    </array>
    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF
    echo "✅ Created Info.plist"
fi

echo ""
echo "📦 Listing source files:"
find YTAudioPlayer -name "*.swift" -type f | grep -v ".build" | head -20

echo ""
echo "🔨 Building..."

# Clean first
xcodebuild clean -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer 2>/dev/null || true

# Build for generic iOS (no signing needed)
xcodebuild \
    -project YTAudioPlayer.xcodeproj \
    -scheme YTAudioPlayer \
    -destination 'generic/platform=iOS' \
    -configuration Debug \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    build

echo ""
echo "✅ Build succeeded!"
echo ""
echo "To install on device:"
echo "1. Open YTAudioPlayer.xcodeproj in Xcode"
echo "2. Set your Team in Signing & Capabilities"
echo "3. Connect device and run"
