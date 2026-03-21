# iOS Project Setup - Quick Start

Since Xcode projects can't be easily created from templates, you have two options:

## Option 1: Manual Xcode Project Creation (Recommended)

This takes about 2 minutes and gives you full control.

### Step 1: Create New Project
1. Open **Xcode** (from Applications)
2. Click **"Create New Project"** (or File → New → Project)
3. Select **iOS** tab → **App** template → Click **Next**

### Step 2: Configure Project
Fill in the details:
- **Name**: `YTAudioPlayer`
- **Team**: Your Apple ID (or None for simulator)
- **Organization Identifier**: `com.yourname` (or anything)
- **Interface**: `SwiftUI`
- **Language**: `Swift`
- **Minimum iOS Version**: `16.0`

Click **Next**, then save to: `YTAudioSystem/ios/` folder

### Step 3: Replace Source Files
In Finder:
1. Navigate to `YTAudioSystem/ios/YTAudioPlayer/`
2. You'll see the new project Xcode created
3. **Replace** the auto-generated files with our files:
   - Replace `ContentView.swift` with our version
   - Add `Models/`, `Sources/`, `Views/` folders we provided

Or in Xcode:
1. Delete auto-generated `ContentView.swift`
2. Drag our folders (Models, Sources, Views) into the project navigator
3. Check "Copy items if needed" and select your target

### Step 4: Configure Info.plist
1. Click on project name in navigator
2. Select target → **Info** tab
3. Add these keys by clicking **+**:

| Key | Type | Value |
|-----|------|-------|
| `UIBackgroundModes` | Array | Add item: `audio` |
| `NSAppTransportSecurity` | Dictionary | Add subkey: `NSAllowsArbitraryLoads` = YES |

Or simply copy our `Info.plist` contents into yours.

### Step 5: Update Backend IP
Open `Sources/APIService.swift` and change:
```swift
private let baseURL = "http://192.x.x.x:8080"  // Your Mac's IP
```

Find your IP: `System Preferences → Network` or run `ifconfig`

### Step 6: Build and Run
1. Select your iPhone at top (or "My Mac" for simulator)
2. Press **Cmd+R** to build and run

---

## Option 2: Use the Shell Script

Run the provided script:
```bash
cd YTAudioSystem/ios
chmod +x create_project.sh
./create_project.sh
```

This creates a Swift Package Manager project that can be built from command line, but for iOS apps with specific entitlements (like background audio), Xcode GUI setup is still recommended.

---

## Troubleshooting

### "No such module 'AVFoundation'"
Make sure you selected **iOS App** template, not macOS or other.

### "Signing for YTAudioPlayer requires a development team"
1. Click project name in navigator
2. Select target → **Signing & Capabilities**
3. Select your Apple ID under **Team**
   - If no Apple ID: Click "Add Account..." and sign in
   - Or use "None" for simulator only

### "Cannot connect to server"
1. Make sure backend is running: `cd YTAudioSystem && make backend`
2. Check IP address matches your Mac's current IP
3. Ensure iPhone and Mac are on same WiFi

### "App runs but no audio"
- Check that you added `audio` to `UIBackgroundModes`
- Check `NSAllowsArbitraryLoads` is set to YES
- Try building for device instead of simulator

---

## Need Help?

The source files are already complete and ready. You just need to create the Xcode project container and copy them in. The heavy lifting is done!
