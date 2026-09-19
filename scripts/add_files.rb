require 'xcodeproj'

PROJECT_PATH = File.expand_path('../LLMUsageCounter.xcodeproj', __dir__)
REPO_ROOT    = File.expand_path('..', __dir__)

proj   = Xcodeproj::Project.open(PROJECT_PATH)
target = proj.targets.find { |t| t.name == 'LLMUsageCounter' }
raise "Target 'LLMUsageCounter' not found" unless target

# ── 1. Remove stale generated files ──────────────────────────────────────────
STALE = %w[ContentView.swift LLMUsageCounterApp.swift].freeze

proj.files.select { |f| STALE.include?(File.basename(f.path)) }.each do |ref|
  puts "  removing stale reference: #{ref.path}"
  target.source_build_phase.remove_file_reference(ref)
  ref.remove_from_project
end

# ── 2. Helper: find or create a group by path segments ───────────────────────
def find_or_create_group(parent, *segments)
  segments.reduce(parent) do |grp, seg|
    grp[seg] || grp.new_group(seg, seg)
  end
end

# ── 3. Helper: add a file reference + build phase entry ──────────────────────
def add_swift_file(proj, target, group, abs_path)
  rel_path = abs_path.sub(REPO_ROOT + '/', '')
  # Skip if a reference with this path already exists anywhere in the project
  return if proj.files.any? { |f| f.real_path.to_s == abs_path }

  ref = group.new_file(rel_path)
  ref.source_tree = 'SOURCE_ROOT'
  target.source_build_phase.add_file_reference(ref)
  puts "  added: #{rel_path}"
  ref
end

# ── 4. Define file groups and their target membership ────────────────────────
# Format: [ group_path_segments, glob_pattern, [targets] ]
additions = [
  # Shared — compiled into main app target only for now
  # (widget target membership added manually or via milestone 3 script)
  [['Shared', 'Models'],   'Shared/Models/*.swift',   [target]],
  [['Shared', 'Storage'],  'Shared/Storage/*.swift',  [target]],
  [['Shared', 'Views'],    'Shared/Views/*.swift',    [target]],

  # App — main target only
  [['App'],                'App/*.swift',             [target]],
  [['App', 'Providers'],   'App/Providers/*.swift',   [target]],
  [['App', 'Keychain'],    'App/Keychain/*.swift',    [target]],
  [['App', 'Views'],       'App/Views/*.swift',       [target]],
  [['App', 'Views', 'ProviderSetup'], 'App/Views/ProviderSetup/*.swift', [target]],
]

root_group = proj.main_group

additions.each do |segments, glob, targets|
  group = find_or_create_group(root_group, *segments)
  Dir.glob(File.join(REPO_ROOT, glob)).sort.each do |abs_path|
    next unless abs_path.end_with?('.swift')
    ref = add_swift_file(proj, targets.first, group, abs_path)
    # If multiple targets (e.g. widget), add to remaining targets too
    if ref && targets.length > 1
      targets[1..].each { |t| t.source_build_phase.add_file_reference(ref) }
    end
  end
end

# ── 5. Save ───────────────────────────────────────────────────────────────────
proj.save
puts "\nDone. project.pbxproj updated."
puts "Next: open Xcode, verify the groups appear, then build (Cmd+B)."
