#!/usr/bin/env python3
"""
OAuth Setup Script
Optional: Run this to enable authenticated features.
Without authentication, the app works in guest mode for search/streaming.
"""

import os
from ytmusicapi import setup


def main():
    print("YouTube Music Authentication Setup (Optional)")
    print("=" * 50)
    print()
    print("ℹ️  This step is OPTIONAL")
    print()
    print("Without authentication:")
    print("  ✅ Search for songs")
    print("  ✅ Stream audio")
    print("  ✅ Download to local library")
    print("  ✅ Get lyrics")
    print()
    print("With authentication:")
    print("  ✅ Access your liked songs")
    print("  ✅ Access your playlists")
    print("  ✅ Better recommendations")
    print("  ✅ Upload music to your library")
    print()
    
    auth_file = "oauth.json"
    
    if os.path.exists(auth_file):
        print(f"⚠️  {auth_file} already exists.")
        response = input("Overwrite? (y/N): ")
        if response.lower() != 'y':
            print("Setup cancelled. Existing auth will be used.")
            return
        os.remove(auth_file)
    
    print("Choose authentication method:")
    print()
    print("1. BROWSER HEADERS (Recommended - Easiest)")
    print("   - Copy cookie from your browser")
    print("   - Works immediately")
    print()
    print("2. Skip (Use Guest Mode)")
    print("   - No authentication needed")
    print("   - Basic features work")
    print()
    
    choice = input("Choose (1/2) [2]: ").strip() or "2"
    
    if choice == "1":
        print()
        print("Browser Headers Method")
        print("-" * 30)
        print()
        print("Please follow these steps:")
        print()
        print("1. Open Chrome/Firefox and go to: https://music.youtube.com")
        print("2. Sign in to your Google account")
        print("3. Open Developer Tools (F12 or Cmd+Option+I)")
        print("4. Go to the Network tab")
        print("5. Refresh the page (F5)")
        print("6. Click on any request (e.g., 'browse')")
        print("7. Scroll down to 'Request Headers'")
        print("8. Right-click on 'cookie' and select 'Copy value'")
        print()
        
        input("Press Enter when ready to paste...")
        print()
        
        try:
            headers = setup(filepath=auth_file)
            
            if os.path.exists(auth_file):
                print()
                print(f"✓ Authentication successful!")
                print(f"✓ Credentials saved to {auth_file}")
                print()
                print("Restart the server to use authenticated features:")
                print("  Ctrl+C to stop, then: make backend")
            else:
                print()
                print("⚠️  Something went wrong. File not created.")
                
        except Exception as e:
            print(f"✗ Setup failed: {e}")
            print()
            print("You can still use the app without authentication!")
            print("Run: make backend")
            
    else:
        print()
        print("✓ Guest mode selected")
        print()
        print("The app will work without authentication.")
        print("You can always add auth later by running: make auth")
        print()
        print("Start the server:")
        print("  make backend")


if __name__ == "__main__":
    main()
