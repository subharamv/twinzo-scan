# XcodeGen writes objectVersion 77 (Xcode 16+), which Xcode 15.4 cannot read.
# This postGenerationCommand pins the generated project to a format Xcode 15.4
# understands so CI can build it. See project.yml -> options.postGenCommand.
require 'fileutils'

pbxproj = 'TwinzoScan.xcodeproj/project.pbxproj'
version = 60

contents = File.read(pbxproj)
updated = contents.gsub(/objectVersion = \d+;/, "objectVersion = #{version};")

if updated == contents
  warn "fix-object-version: no objectVersion found in #{pbxproj}; nothing to change"
  exit 0
end

File.write(pbxproj, updated)
puts "fix-object-version: pinned objectVersion to #{version}"
