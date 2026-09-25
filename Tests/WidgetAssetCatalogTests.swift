import Foundation

// The widget renders the same QuotaCardView as the app and looks each
// provider's logo up by name in its own bundle, so it needs its own copy of
// every logo. Widget/Assets.xcassets was never in the widget's build and had
// already drifted (no Grok or OpenRouter) before anyone noticed; these checks
// keep the two catalogs in step.

private enum WidgetAssetTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw WidgetAssetTestError.failure(message) }
}

private let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
private let appCatalog = root.appendingPathComponent("LLMUsageCounter/Assets.xcassets", isDirectory: true)
private let widgetCatalog = root.appendingPathComponent("Widget/Assets.xcassets", isDirectory: true)

private func imagesetFiles(_ catalog: URL, _ name: String) throws -> [String: Data] {
    let folder = catalog.appendingPathComponent("\(name).imageset", isDirectory: true)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
    var files: [String: Data] = [:]
    for file in names {
        files[file] = try Data(contentsOf: folder.appendingPathComponent(file))
    }
    return files
}

private func testEveryProviderLogoIsInBothCatalogs() throws {
    for providerID in ProviderID.allCases {
        let name = providerID.bundledLogoAssetName
        guard !name.isEmpty else { continue }
        let app = try? imagesetFiles(appCatalog, name)
        let widget = try? imagesetFiles(widgetCatalog, name)
        try expect(app != nil, "\(providerID.rawValue): \(name) is missing from the app's catalog")
        try expect(widget != nil, "\(providerID.rawValue): \(name) is missing from Widget/Assets.xcassets")
        try expect(app == widget, "\(providerID.rawValue): the widget's \(name) differs from the app's")
    }
}

private func testEveryAppLogoSetIsInTheWidget() throws {
    let logoSets = try FileManager.default.contentsOfDirectory(atPath: appCatalog.path)
        .filter { $0.hasPrefix("Provider") && $0.hasSuffix("Logo.imageset") }
    for set in logoSets {
        let name = String(set.dropLast(".imageset".count))
        try expect(
            (try? imagesetFiles(appCatalog, name)) == (try? imagesetFiles(widgetCatalog, name)),
            "\(name) is not the same in Widget/Assets.xcassets as in the app's catalog"
        )
    }
}

private func testTheWidgetTargetBundlesItsCatalog() throws {
    let project = try String(
        contentsOf: root.appendingPathComponent("LLMUsageCounter.xcodeproj/project.pbxproj"),
        encoding: .utf8
    )
    try expect(
        project.contains("path = Widget/Assets.xcassets;"),
        "the project references Widget/Assets.xcassets"
    )
    // The widget target's Resources phase lists the catalog.
    guard let phase = project.range(of: "86AFB6DEBF7801AB676DDC79 /* Resources */ = {"),
          let end = project[phase.upperBound...].range(of: "};") else {
        throw WidgetAssetTestError.failure("the widget target's Resources phase is missing")
    }
    try expect(
        project[phase.upperBound..<end.lowerBound].contains("Assets.xcassets in Resources"),
        "the widget target's Resources phase compiles its asset catalog"
    )
}

@main
private enum WidgetAssetCatalogTestRunner {
    static func main() throws {
        try testEveryProviderLogoIsInBothCatalogs()
        try testEveryAppLogoSetIsInTheWidget()
        try testTheWidgetTargetBundlesItsCatalog()
        print("Widget asset catalog tests passed")
    }
}
