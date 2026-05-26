#!/usr/bin/env ruby
# Generates her-ios/macos/HerMac.xcodeproj as a standalone macOS app target.
#
# Re-run any time the source layout changes; the project is overwritten.
# Requires the `xcodeproj` gem:
#   gem install --user-install xcodeproj

require 'xcodeproj'
require 'fileutils'
require 'pathname'

MACOS_DIR     = Pathname.new(__dir__).join('..').realpath
PROJECT_PATH  = MACOS_DIR.join('HerMac.xcodeproj')
SHARED_PKG    = MACOS_DIR.join('..', 'shared').realpath
SOURCES_DIR   = MACOS_DIR.join('Sources', 'HerMac')
INFO_PLIST    = MACOS_DIR.join('Resources', 'Info.plist')
ENTITLEMENTS  = MACOS_DIR.join('Resources', 'HerMac.entitlements')

TEAM_ID       = '6UNHXUUR5T'
BUNDLE_ID     = 'com.ekenesbek.her.mac'
PRODUCT_NAME  = 'Her'
TARGET_NAME   = 'HerMac'
DEPLOY_MIN    = '14.0'
SWIFT_VERSION = '5.9'

raise "Sources dir missing: #{SOURCES_DIR}"   unless SOURCES_DIR.directory?
raise "Info.plist missing: #{INFO_PLIST}"     unless INFO_PLIST.file?
raise "Entitlements missing: #{ENTITLEMENTS}" unless ENTITLEMENTS.file?
raise "Shared package missing: #{SHARED_PKG}" unless SHARED_PKG.directory?

# Wipe old project so the script is idempotent.
FileUtils.rm_rf(PROJECT_PATH) if PROJECT_PATH.exist?

project = Xcodeproj::Project.new(PROJECT_PATH.to_s)

# --- Local Swift Package: HerShared --------------------------------------
local_pkg = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
local_pkg.relative_path = SHARED_PKG.relative_path_from(MACOS_DIR).to_s
project.root_object.package_references << local_pkg

her_shared_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
her_shared_dep.package      = local_pkg
her_shared_dep.product_name = 'HerShared'

# --- Main app target -----------------------------------------------------
target = project.new_target(:application, TARGET_NAME, :osx, DEPLOY_MIN, nil, :swift)
target.product_name = PRODUCT_NAME

# Source files
src_group = project.main_group.new_group(TARGET_NAME, SOURCES_DIR.relative_path_from(MACOS_DIR).to_s)
SOURCES_DIR.glob('*.swift').sort.each do |swift_file|
  ref = src_group.new_file(swift_file.basename.to_s)
  target.add_file_references([ref])
end

# Info.plist + entitlements live as references but not in any build phase
resources_group = project.main_group.new_group('Resources', 'Resources')
resources_group.new_file(INFO_PLIST.basename.to_s)
resources_group.new_file(ENTITLEMENTS.basename.to_s)

# Wire the HerShared package product into the target
target.package_product_dependencies << her_shared_dep
frameworks_phase = target.frameworks_build_phase
frameworks_phase.add_file_reference(
  project.new(Xcodeproj::Project::Object::PBXBuildFile).tap { |bf| bf.product_ref = her_shared_dep }
).tap do |_|
  # nothing further; the build file is attached to the frameworks phase
end if false # xcodeproj 1.27 wires this automatically via package_product_dependencies

# --- Build settings ------------------------------------------------------
common_settings = {
  'PRODUCT_BUNDLE_IDENTIFIER'    => BUNDLE_ID,
  'PRODUCT_NAME'                 => PRODUCT_NAME,
  'MACOSX_DEPLOYMENT_TARGET'     => DEPLOY_MIN,
  'SDKROOT'                      => 'macosx',
  'SUPPORTED_PLATFORMS'          => 'macosx',
  'SWIFT_VERSION'                => SWIFT_VERSION,
  'DEVELOPMENT_TEAM'             => TEAM_ID,
  'CODE_SIGN_STYLE'              => 'Automatic',
  'CODE_SIGN_IDENTITY'           => 'Apple Development',
  'CODE_SIGN_ENTITLEMENTS'       => 'Resources/HerMac.entitlements',
  'INFOPLIST_FILE'               => 'Resources/Info.plist',
  'ENABLE_HARDENED_RUNTIME'      => 'YES',
  'ENABLE_PREVIEWS'              => 'YES',
  'ASSETCATALOG_COMPILER_APPICON_NAME' => '',
  'COMBINE_HIDPI_IMAGES'         => 'YES',
  'CURRENT_PROJECT_VERSION'      => '1',
  'MARKETING_VERSION'            => '0.4.2',
  'GENERATE_INFOPLIST_FILE'      => 'NO',
  'LD_RUNPATH_SEARCH_PATHS'      => '$(inherited) @executable_path/../Frameworks'
}

target.build_configurations.each do |config|
  config.build_settings.merge!(common_settings)
  if config.name == 'Debug'
    config.build_settings['SWIFT_OPTIMIZATION_LEVEL']      = '-Onone'
    config.build_settings['ONLY_ACTIVE_ARCH']              = 'YES'
    config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
    config.build_settings['GCC_PREPROCESSOR_DEFINITIONS']  = ['DEBUG=1', '$(inherited)']
  else
    config.build_settings['SWIFT_OPTIMIZATION_LEVEL']      = '-O'
    config.build_settings['SWIFT_COMPILATION_MODE']        = 'wholemodule'
  end
end

# Top-level project settings
project.build_configurations.each do |config|
  config.build_settings.merge!(
    'ALWAYS_SEARCH_USER_PATHS' => 'NO',
    'CLANG_ENABLE_OBJC_ARC'    => 'YES',
    'CLANG_WARN_DOCUMENTATION_COMMENTS' => 'YES',
    'COPY_PHASE_STRIP'         => 'NO',
    'ENABLE_STRICT_OBJC_MSGSEND' => 'YES',
    'GCC_NO_COMMON_BLOCKS'     => 'YES',
    'GCC_WARN_UNDECLARED_SELECTOR' => 'YES',
    'GCC_WARN_UNINITIALIZED_AUTOS' => 'YES_AGGRESSIVE',
    'GCC_WARN_UNUSED_FUNCTION' => 'YES',
    'GCC_WARN_UNUSED_VARIABLE' => 'YES',
    'MACOSX_DEPLOYMENT_TARGET' => DEPLOY_MIN,
    'SDKROOT'                  => 'macosx',
    'SWIFT_VERSION'            => SWIFT_VERSION
  )
end

# --- Scheme so xcodebuild can find it ------------------------------------
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(PROJECT_PATH.to_s, TARGET_NAME, true)

# Mark the scheme as shared so xcodebuild -scheme HerMac works
shared_dir = PROJECT_PATH.join('xcshareddata', 'xcschemes')
FileUtils.mkdir_p(shared_dir)
user_scheme = PROJECT_PATH.join('xcuserdata').glob('*.xcuserdatad/xcschemes/HerMac.xcscheme').first
if user_scheme
  FileUtils.cp(user_scheme, shared_dir.join('HerMac.xcscheme'))
end

puts "Wrote #{PROJECT_PATH}"
puts "Targets:"
project.targets.each { |t| puts "  - #{t.name}" }
