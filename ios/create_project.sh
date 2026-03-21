#!/bin/bash
# Create Xcode project for YTAudioPlayer
# Run this once to generate the .xcodeproj file

echo "Creating YTAudioPlayer Xcode Project"
echo "====================================="
echo ""

# Check if Swift is installed
if ! command -v swift &> /dev/null; then
    echo "❌ Swift not found. Please install Xcode."
    exit 1
fi

# Check if xcodebuild is available
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ xcodebuild not found. Please install Xcode Command Line Tools:"
    echo "   xcode-select --install"
    exit 1
fi

# Create project directory structure
mkdir -p YTAudioPlayer/Preview\ Content

# Create Info.plist
cat > YTAudioPlayer/Info.plist << 'EOF'
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
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
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

echo "✓ Created Info.plist"

# Try to use Swift Package Manager to create a project
echo ""
echo "Option 1: Using Swift Package Manager (Recommended for CLI)"
echo "   This creates a Swift Package that can be built from command line."
echo ""

# Create Package.swift
cat > Package.swift << 'EOF'
// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "YTAudioPlayer",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "YTAudioPlayer", targets: ["YTAudioPlayer"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "YTAudioPlayer",
            path: "YTAudioPlayer",
            exclude: ["Info.plist"]
        ),
    ]
)
EOF

echo "✓ Created Package.swift"

echo ""
echo "=============================================="
echo "PROJECT CREATED!"
echo "=============================================="
echo ""
echo "You have two options to open/build:"
echo ""
echo "Option A: Open in Xcode (GUI)"
echo "   1. Open Xcode"
echo "   2. Choose 'Open a project or file'"
echo "   3. Select the folder: $(pwd)"
echo "   4. Xcode will create a project for you"
echo ""
echo "Option B: Use Swift Package Manager (CLI)"
echo "   Build from command line with:"
echo "   swift build"
echo ""
echo "NOTE: Since this is an iOS app with specific"
echo "      requirements (audio background mode),"
echo "      Option A (Xcode GUI) is recommended."
echo ""
