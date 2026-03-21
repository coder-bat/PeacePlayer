jnklkjmkl bimn8-#!/usr/bin/env python3
import json
import os
import re
import sys
import hashlib
import uuid

def generate_id(filename):
    """Generate a deterministic Xcode-style ID from filename"""
    hash_val = hashlib.md5(filename.encode()).hexdigest()[:24].upper()
    return hash_val

def add_file_to_project(project_path, filename, group="Sources"):
    with open(project_path, 'r') as f:
        content = f.read()
    
    # Generate IDs
    file_ref_id = generate_id(f"ref_{filename}")
    build_file_id = generate_id(f"build_{filename}")
    
    # Check if already exists
    if filename in content:
        print(f"{filename} already in project")
        return
    
    # Add PBXFileReference (after PlaylistManager.swift ref)
    file_ref_line = f"\t\t{file_ref_id} /* {filename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {filename}; sourceTree = \"<group>\"; }};\n"
    
    # Find the line with PlaylistManager.swift reference and add after
    ref_pattern = r'(\t\t7D705998327EFF69651CA0CF /\* PlaylistManager\.swift \*/ = \{[^}]+\};\n)'
    match = re.search(ref_pattern, content)
    if match:
        insert_pos = match.end()
        content = content[:insert_pos] + file_ref_line + content[insert_pos:]
    
    # Add PBXBuildFile (after PlaylistManager.swift build)
    build_file_line = f"\t\t{build_file_id} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {filename} */; }};\n"
    
    build_pattern = r'(\t\t85E47522BAAA0B45C63ECDB1 /\* PlaylistManager\.swift in Sources \*/ = \{[^}]+\};\n)'
    match = re.search(build_pattern, content)
    if match:
        insert_pos = match.end()
        content = content[:insert_pos] + build_file_line + content[insert_pos:]
    
    # Add to PBXGroup Sources (after PlaylistManager.swift)
    group_pattern = r'(\t\t\t\t7D705998327EFF69651CA0CF /\* PlaylistManager\.swift \*/,\n)'
    match = re.search(group_pattern, content)
    if match:
        insert_pos = match.end()
        content = content[:insert_pos] + f"\t\t\t\t{file_ref_id} /* {filename} */,\n" + content[insert_pos:]
    
    # Add to PBXSourcesBuildPhase (after PlaylistManager.swift)
    sources_pattern = r'(\t\t\t\t85E47522BAAA0B45C63ECDB1 /\* PlaylistManager\.swift in Sources \*/,\n)'
    match = re.search(sources_pattern, content)
    if match:
        insert_pos = match.end()
        content = content[:insert_pos] + f"\t\t\t\t{build_file_id} /* {filename} in Sources */,\n" + content[insert_pos:]
    
    with open(project_path, 'w') as f:
        f.write(content)
    
    print(f"Added {filename} to project")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python add_file_to_project.py <filename>")
        sys.exit(1)
    
    project_path = os.path.join(os.path.dirname(__file__), "YTAudioPlayer.xcodeproj/project.pbxproj")
    filename = sys.argv[1]
    add_file_to_project(project_path, filename)
