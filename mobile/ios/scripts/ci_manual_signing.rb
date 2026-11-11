#!/usr/bin/env ruby
# Switches the Release configuration of Runner and NotificationService to manual
# signing with the given App Store profiles. CI only: the testflight workflow runs
# it on a throwaway checkout so local builds keep automatic signing.
#
# Command-line build settings can't do this, because they apply to every target
# (including Swift packages, which reject provisioning profiles) and the two app
# targets need different profiles.
#
#   gem install xcodeproj
#   ruby ios/scripts/ci_manual_signing.rb TEAM_ID APP_PROFILE_NAME EXTENSION_PROFILE_NAME
require 'xcodeproj'

team, app_profile, extension_profile = ARGV
abort 'usage: ci_manual_signing.rb TEAM_ID APP_PROFILE_NAME EXTENSION_PROFILE_NAME' unless extension_profile

profiles = { 'Runner' => app_profile, 'NotificationService' => extension_profile }
project = Xcodeproj::Project.open(File.expand_path('../Runner.xcodeproj', __dir__))

profiles.each do |target_name, profile|
  target = project.targets.find { |t| t.name == target_name } or abort "no #{target_name} target"
  config = target.build_configurations.find { |c| c.name == 'Release' } or abort "no Release config on #{target_name}"
  settings = config.build_settings
  settings['CODE_SIGN_STYLE'] = 'Manual'
  settings['DEVELOPMENT_TEAM'] = team
  settings['CODE_SIGN_IDENTITY'] = 'Apple Distribution'
  settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = 'Apple Distribution'
  settings['PROVISIONING_PROFILE_SPECIFIER'] = profile
  puts "#{target_name} (Release): manual signing with \"#{profile}\""
end

project.save
