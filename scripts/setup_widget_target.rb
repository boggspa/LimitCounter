require 'fileutils'
require 'pathname'
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../LLMUsageCounter.xcodeproj', __dir__)
REPO_ROOT = File.expand_path('..', __dir__)
APP_TARGET_NAME = 'LLMUsageCounter'
WIDGET_TARGET_NAME = 'AIUsageWidgetExtension'
WIDGET_BUNDLE_ID = 'com.chrisizatt.LLMUsageCounter.widget'
WIDGET_INFO_PLIST = File.join(REPO_ROOT, 'Widget/AIUsageWidgetExtension-Info.plist')
APP_SCHEME_PATH = File.join(REPO_ROOT, 'LLMUsageCounter.xcodeproj/xcshareddata/xcschemes/LLMUsageCounter.xcscheme')

project = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |target| target.name == APP_TARGET_NAME }
raise "Target '#{APP_TARGET_NAME}' not found" unless app_target

widget_target = project.targets.find { |target| target.name == WIDGET_TARGET_NAME }
unless widget_target
  widget_target = project.new_target(:app_extension, WIDGET_TARGET_NAME, :ios, '26.2')
end

team_id = app_target.build_configurations.first.build_settings['DEVELOPMENT_TEAM']
widget_group = project.main_group['Widget'] || project.main_group.new_group('Widget', 'Widget')

def ensure_file_reference(project, group, absolute_path)
  existing = project.files.find { |file| file.real_path.to_s == absolute_path }
  return existing if existing

  relative_path = Pathname.new(absolute_path).relative_path_from(Pathname.new(REPO_ROOT)).to_s
  reference = group.new_file(relative_path)
  reference.source_tree = 'SOURCE_ROOT'
  reference
end

def add_source_to_target(target, file_reference)
  return if target.source_build_phase.files_references.include?(file_reference)

  target.source_build_phase.add_file_reference(file_reference)
end

def apply_build_settings(target, values)
  target.build_configurations.each do |configuration|
    values.each do |key, value|
      configuration.build_settings[key] = value
    end
  end
end

widget_source = File.join(REPO_ROOT, 'Widget/QuotaTimelineProvider.swift')
ensure_file_reference(project, widget_group, widget_source).tap do |reference|
  add_source_to_target(widget_target, reference)
end

Dir.glob(File.join(REPO_ROOT, 'Shared/**/*.swift')).sort.each do |absolute_path|
  reference = ensure_file_reference(project, project.main_group, absolute_path)
  add_source_to_target(widget_target, reference)
end

ensure_file_reference(project, widget_group, File.join(REPO_ROOT, 'Widget/AIUsageWidgetExtension-Info.plist'))
ensure_file_reference(project, widget_group, File.join(REPO_ROOT, 'Widget/AIUsageWidgetExtension.iOS.entitlements'))
ensure_file_reference(project, widget_group, File.join(REPO_ROOT, 'Widget/AIUsageWidgetExtension.macOS.entitlements'))

unless File.exist?(WIDGET_INFO_PLIST)
  File.write(
    WIDGET_INFO_PLIST,
    <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>$(DEVELOPMENT_LANGUAGE)</string>
        <key>CFBundleDisplayName</key>
        <string>AI Usage Widget</string>
        <key>CFBundleExecutable</key>
        <string>$(EXECUTABLE_NAME)</string>
        <key>CFBundleIdentifier</key>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>$(PRODUCT_NAME)</string>
        <key>CFBundlePackageType</key>
        <string>XPC!</string>
        <key>CFBundleShortVersionString</key>
        <string>$(MARKETING_VERSION)</string>
        <key>CFBundleVersion</key>
        <string>$(CURRENT_PROJECT_VERSION)</string>
        <key>NSExtension</key>
        <dict>
            <key>NSExtensionPointIdentifier</key>
            <string>com.apple.widgetkit-extension</string>
        </dict>
      </dict>
      </plist>
    PLIST
  )
end

app_target.build_configurations.each do |configuration|
  configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'LLMUsageCounter/LLMUsageCounter.iOS.entitlements'
  configuration.build_settings['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = 'LLMUsageCounter/LLMUsageCounter.macOS.entitlements'
end

widget_target.product_type = 'com.apple.product-type.app-extension'

apply_build_settings(
  widget_target,
  'APPLICATION_EXTENSION_API_ONLY' => 'YES',
  'CODE_SIGN_ENTITLEMENTS' => 'Widget/AIUsageWidgetExtension.iOS.entitlements',
  'CODE_SIGN_ENTITLEMENTS[sdk=macosx*]' => 'Widget/AIUsageWidgetExtension.macOS.entitlements',
  'CODE_SIGN_STYLE' => 'Automatic',
  'CURRENT_PROJECT_VERSION' => '1',
  'DEVELOPMENT_TEAM' => team_id,
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'INFOPLIST_FILE' => 'Widget/AIUsageWidgetExtension-Info.plist',
  'IPHONEOS_DEPLOYMENT_TARGET' => '26.2',
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks',
  'MACOSX_DEPLOYMENT_TARGET' => '26.0',
  'MARKETING_VERSION' => '1.0',
  'PRODUCT_BUNDLE_IDENTIFIER' => WIDGET_BUNDLE_ID,
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'REGISTER_APP_GROUPS' => 'YES',
  'SDKROOT' => 'auto',
  'SKIP_INSTALL' => 'YES',
  'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator macosx',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
  'SWIFT_VERSION' => '5.0',
  'TARGETED_DEVICE_FAMILY' => '1,2'
)

unless app_target.dependencies.any? { |dependency| dependency.target == widget_target }
  app_target.add_dependency(widget_target)
end

embed_phase = app_target.copy_files_build_phases.find { |phase| phase.name == 'Embed App Extensions' }
embed_phase ||= app_target.new_copy_files_build_phase('Embed App Extensions')
embed_phase.dst_subfolder_spec = '13'
embed_phase.dst_path = ''

unless embed_phase.files_references.include?(widget_target.product_reference)
  build_file = embed_phase.add_file_reference(widget_target.product_reference)
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

project.save

unless File.exist?(APP_SCHEME_PATH)
  FileUtils.mkdir_p(File.dirname(APP_SCHEME_PATH))
  File.write(
    APP_SCHEME_PATH,
    <<~SCHEME
      <?xml version="1.0" encoding="UTF-8"?>
      <Scheme
         LastUpgradeVersion = "2630"
         version = "2.0">
         <BuildAction
            parallelizeBuildables = "YES"
            buildImplicitDependencies = "YES"
            buildArchitectures = "Automatic">
            <BuildActionEntries>
               <BuildActionEntry
                  buildForTesting = "YES"
                  buildForRunning = "YES"
                  buildForProfiling = "YES"
                  buildForArchiving = "YES"
                  buildForAnalyzing = "YES">
                  <BuildableReference
                     BuildableIdentifier = "primary"
                     BlueprintIdentifier = "#{app_target.uuid}"
                     BuildableName = "#{app_target.product_reference.path}"
                     BlueprintName = "#{app_target.name}"
                     ReferencedContainer = "container:LLMUsageCounter.xcodeproj">
                  </BuildableReference>
               </BuildActionEntry>
            </BuildActionEntries>
         </BuildAction>
         <TestAction
            buildConfiguration = "Debug"
            selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
            selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
            shouldUseLaunchSchemeArgsEnv = "YES"
            shouldAutocreateTestPlan = "YES">
            <MacroExpansion>
               <BuildableReference
                  BuildableIdentifier = "primary"
                  BlueprintIdentifier = "#{app_target.uuid}"
                  BuildableName = "#{app_target.product_reference.path}"
                  BlueprintName = "#{app_target.name}"
                  ReferencedContainer = "container:LLMUsageCounter.xcodeproj">
               </BuildableReference>
            </MacroExpansion>
         </TestAction>
         <LaunchAction
            buildConfiguration = "Debug"
            selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
            selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
            launchStyle = "0"
            useCustomWorkingDirectory = "NO"
            ignoresPersistentStateOnLaunch = "NO"
            debugDocumentVersioning = "YES"
            debugServiceExtension = "internal"
            allowLocationSimulation = "YES">
            <BuildableProductRunnable
               runnableDebuggingMode = "0">
               <BuildableReference
                  BuildableIdentifier = "primary"
                  BlueprintIdentifier = "#{app_target.uuid}"
                  BuildableName = "#{app_target.product_reference.path}"
                  BlueprintName = "#{app_target.name}"
                  ReferencedContainer = "container:LLMUsageCounter.xcodeproj">
               </BuildableReference>
            </BuildableProductRunnable>
         </LaunchAction>
         <ProfileAction
            buildConfiguration = "Release"
            shouldUseLaunchSchemeArgsEnv = "YES"
            savedToolIdentifier = ""
            useCustomWorkingDirectory = "NO"
            debugDocumentVersioning = "YES">
            <BuildableProductRunnable
               runnableDebuggingMode = "0">
               <BuildableReference
                  BuildableIdentifier = "primary"
                  BlueprintIdentifier = "#{app_target.uuid}"
                  BuildableName = "#{app_target.product_reference.path}"
                  BlueprintName = "#{app_target.name}"
                  ReferencedContainer = "container:LLMUsageCounter.xcodeproj">
               </BuildableReference>
            </BuildableProductRunnable>
         </ProfileAction>
         <AnalyzeAction
            buildConfiguration = "Debug">
         </AnalyzeAction>
         <ArchiveAction
            buildConfiguration = "Release"
            revealArchiveInOrganizer = "YES">
         </ArchiveAction>
      </Scheme>
    SCHEME
  )
end

puts "Configured #{WIDGET_TARGET_NAME} and updated #{APP_TARGET_NAME} entitlements."
