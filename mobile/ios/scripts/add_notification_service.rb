#!/usr/bin/env ruby
# Adds the NotificationService extension (decrypts alert pushes) to
# Runner.xcodeproj and wires up per-configuration Runner entitlements.
# Idempotent: re-running converges on the same project.
#
#   gem install xcodeproj   # ships with CocoaPods
#   ruby ios/scripts/add_notification_service.rb
require 'xcodeproj'

IOS_DIR = File.expand_path('..', __dir__)
NSE = 'NotificationService'
NSE_BUNDLE_ID = 'xyz.vidur.pux.NotificationService'
SODIUM_URL = 'https://github.com/jedisct1/swift-sodium.git'
SODIUM_MIN_VERSION = '0.11.0'
DEPLOYMENT_TARGET = '15.0'

project = Xcodeproj::Project.open(File.join(IOS_DIR, 'Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' }
runner_tests = project.targets.find { |t| t.name == 'RunnerTests' }

def group_for(project, name)
  project.main_group.children.find { |g| g.display_name == name } ||
    project.main_group.new_group(name, name)
end

def file_in(group, name)
  group.files.find { |f| f.path == name } || group.new_reference(name)
end

def add_source(target, file)
  target.add_file_references([file]) unless target.source_build_phase.files_references.include?(file)
end

def add_package_product(project, target, package, product_name)
  return if target.package_product_dependencies.any? { |d| d.product_name == product_name }

  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = product_name
  target.package_product_dependencies << dependency
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

# Sources
nse_group = group_for(project, NSE)
nse_service = file_in(nse_group, 'NotificationService.swift')
nse_content = file_in(nse_group, 'RelayNotificationContent.swift')
file_in(nse_group, 'Info.plist')
file_in(nse_group, 'NotificationService.entitlements')
shared_keychain = file_in(group_for(project, 'Shared'), 'PuxKeychain.swift')

runner_group = project.main_group.children.find { |g| g.display_name == 'Runner' }
file_in(runner_group, 'RunnerRelease.entitlements')
tests_group = project.main_group.children.find { |g| g.display_name == 'RunnerTests' }
nse_tests = file_in(tests_group, 'NotificationServiceTests.swift')

# Extension target
nse = project.targets.find { |t| t.name == NSE } ||
      project.new_target(:app_extension, NSE, :ios, DEPLOYMENT_TARGET, nil, :swift)
# new_target links Foundation.framework by an SDK-versioned path; Swift
# auto-links it anyway.
project.files.select { |f| f.path.to_s.end_with?('/Foundation.framework') }.each do |f|
  f.build_files.each(&:remove_from_project)
  f.remove_from_project
end
frameworks_group = project.main_group.children.find { |g| g.display_name == 'Frameworks' }
if frameworks_group
  frameworks_group.groups.select { |g| g.children.empty? }.each(&:remove_from_project)
  frameworks_group.remove_from_project if frameworks_group.children.empty?
end
[nse_service, nse_content, shared_keychain].each { |f| add_source(nse, f) }
add_source(runner, shared_keychain)
[nse_content, nse_tests].each { |f| add_source(runner_tests, f) }

xcconfigs = project.files.select { |f| f.path =~ %r{\AFlutter/(Debug|Release)\.xcconfig\z} }
                         .to_h { |f| [File.basename(f.path, '.xcconfig'), f] }

runner.build_configurations.each do |runner_config|
  name = runner_config.name
  config = nse.build_configuration_list[name] ||
           nse.add_build_configuration(name, name == 'Debug' ? :debug : :release)
  # Flutter's xcconfig provides FLUTTER_BUILD_NAME/NUMBER for the Info.plist.
  config.base_configuration_reference = xcconfigs[name == 'Debug' ? 'Debug' : 'Release']
  config.build_settings.merge!(
    'CODE_SIGN_ENTITLEMENTS' => "#{NSE}/#{NSE}.entitlements",
    'CODE_SIGN_STYLE' => 'Automatic',
    'CURRENT_PROJECT_VERSION' => '$(FLUTTER_BUILD_NUMBER)',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => "#{NSE}/Info.plist",
    'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks',
                                  '@executable_path/../../Frameworks'],
    'MARKETING_VERSION' => '$(FLUTTER_BUILD_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => NSE_BUNDLE_ID,
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'SKIP_INSTALL' => 'YES',
    'SWIFT_VERSION' => '5.0',
    'TARGETED_DEVICE_FAMILY' => '1,2'
  )

  runner_config.build_settings['CODE_SIGN_ENTITLEMENTS'] =
    name == 'Debug' ? 'Runner/Runner.entitlements' : 'Runner/RunnerRelease.entitlements'
end

# libsodium (swift-sodium) via Swift Package Manager, like Flutter's own plugins.
sodium = project.root_object.package_references.find do |r|
  r.respond_to?(:repositoryURL) && r.repositoryURL == SODIUM_URL
end
unless sodium
  sodium = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  sodium.repositoryURL = SODIUM_URL
  project.root_object.package_references << sodium
end
sodium.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => SODIUM_MIN_VERSION }
add_package_product(project, nse, sodium, 'Sodium')
add_package_product(project, runner_tests, sodium, 'Sodium')

# Embed the extension. It must come before Flutter's "Thin Binary" script, or
# Xcode reports a dependency cycle.
runner.add_dependency(nse) unless runner.dependencies.any? { |d| d.target == nse }
embed = runner.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' } ||
        runner.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
unless embed.files_references.include?(nse.product_reference)
  embed.add_file_reference(nse.product_reference, true).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
thin_binary = runner.shell_script_build_phases.find { |p| p.name == 'Thin Binary' }
runner.build_phases.delete(embed)
runner.build_phases.insert(runner.build_phases.index(thin_binary), embed)

project.save
puts "#{NSE} target configured in #{project.path}"
