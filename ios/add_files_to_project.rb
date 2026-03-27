#!/usr/bin/env ruby
# Add missing files to Xcode project

require 'securerandom'

# Generate unique IDs (24 hex characters like Xcode uses)
def generate_id
  SecureRandom.hex(12).upcase
end

# Read the project file
pbxproj_path = '/Users/coderbat/iYMusic/YTAudioSystem/ios/YTAudioPlayer.xcodeproj/project.pbxproj'
content = File.read(pbxproj_path)

# Generate IDs for new entries
playback_queue_ref = generate_id  # PBXFileReference for PlaybackQueueManager.swift
playback_queue_build = generate_id  # PBXBuildFile for PlaybackQueueManager.swift
cd_queue_ref = generate_id  # PBXFileReference for CDPlaybackQueue.swift
cd_queue_build = generate_id  # PBXBuildFile for CDPlaybackQueue.swift

puts "Generated IDs:"
puts "  PlaybackQueueManager ref: #{playback_queue_ref}"
puts "  PlaybackQueueManager build: #{playback_queue_build}"
puts "  CDPlaybackQueue ref: #{cd_queue_ref}"
puts "  CDPlaybackQueue build: #{cd_queue_build}"

# 1. Add PBXFileReference entries (after the existing CDDownloadedTrack reference)
# Find a good insertion point - look for CDPlaylist.swift reference
file_ref_entries = <<-RUBY
\t\t#{playback_queue_ref} /* PlaybackQueueManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = PlaybackQueueManager.swift; path = Sources/PlaybackQueueManager.swift; sourceTree = SOURCE_ROOT; };
\t\t#{cd_queue_ref} /* CDPlaybackQueue.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = CDPlaybackQueue.swift; path = Sources/Entities/CDPlaybackQueue.swift; sourceTree = SOURCE_ROOT; };
RUBY

# Insert after CDDownloadedTrack.swift file reference
if content.include?('CDDownloadedTrack.swift') && !content.include?('PlaybackQueueManager.swift')
  content = content.sub(
    /(\t\t785DCEDCD8EB51E04FA7944C \/\* CDDownloadedTrack\.swift \*\/ = \{isa = PBXFileReference;.*?\};)/m,
    "\\1\n#{file_ref_entries.strip}"
  )
  puts "✓ Added PBXFileReference entries"
else
  puts "✗ PBXFileReference already exists or pattern not found"
end

# 2. Add PBXBuildFile entries
build_file_entries = <<-RUBY
\t\t#{playback_queue_build} /* PlaybackQueueManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = #{playback_queue_ref}; };
\t\t#{cd_queue_build} /* CDPlaybackQueue.swift in Sources */ = {isa = PBXBuildFile; fileRef = #{cd_queue_ref}; };
RUBY

if !content.include?('PlaybackQueueManager.swift in Sources')
  # Insert after the last PBXBuildFile entry for CDDownloadedTrack
  content = content.sub(
    /(\t\t1D7074E03ED46E71BA83F90C \/\* CDDownloadedTrack\.swift in Sources \*\/ = \{isa = PBXBuildFile;.*?\};)/,
    "\\1\n#{build_file_entries.strip}"
  )
  puts "✓ Added PBXBuildFile entries"
else
  puts "✗ PBXBuildFile already exists"
end

# 3. Add CDPlaybackQueue.swift to Entities group
if !content.include?('CDPlaybackQueue.swift */,' )
  content = content.sub(
    /(\t\t\tDD1CDA2632A97CF4AA80E901 \/\* CDUserStats\.swift \*\/)/,
    "\\1,\n\t\t\t#{cd_queue_ref} /* CDPlaybackQueue.swift */"
  )
  puts "✓ Added CDPlaybackQueue to Entities group"
else
  puts "✗ CDPlaybackQueue already in Entities group"
end

# 4. Add PlaybackQueueManager.swift to Sources group (need to find the Sources group children section)
# The Sources group ID starts with F2...
if !content.include?('PlaybackQueueManager.swift */,')
  # Add to the main Sources group - look for a file in Sources and add after it
  # Let's add after NowPlayingService.swift
  content = content.sub(
    /(\t\t\tE4DD50078C377D1364FC654B \/\* NowPlayingService\.swift \*\/)/,
    "\\1,\n\t\t\t#{playback_queue_ref} /* PlaybackQueueManager.swift */"
  )
  puts "✓ Added PlaybackQueueManager to Sources group"
else
  puts "✗ PlaybackQueueManager already in Sources group"
end

# 5. Add to PBXSourcesBuildPhase
# Find the Sources build phase section (3FB1536B0624B1DA7DDC96AB) and add entries
if !content.include?('PlaybackQueueManager.swift in Sources */')
  # Add after CDDownloadedTrack entry in Sources build phase
  content = content.sub(
    /(\t\t\t1D7074E03ED46E71BA83F90C \/\* CDDownloadedTrack\.swift in Sources \*\/)/,
    "\\1,\n\t\t\t#{cd_queue_build} /* CDPlaybackQueue.swift in Sources */,\n\t\t\t#{playback_queue_build} /* PlaybackQueueManager.swift in Sources */"
  )
  puts "✓ Added to PBXSourcesBuildPhase"
else
  puts "✗ Already in PBXSourcesBuildPhase"
end

# Write the modified content back
File.write(pbxproj_path, content)
puts "\n✓ Project file updated successfully!"
