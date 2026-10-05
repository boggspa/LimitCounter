import Foundation
import ImageIO

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

private func testDefaultIOSAppStoreIconHasNoAlphaChannel() throws {
    let iconFolder = appCatalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
    let contents = try Data(contentsOf: iconFolder.appendingPathComponent("Contents.json"))
    guard let catalog = try JSONSerialization.jsonObject(with: contents) as? [String: Any],
          let images = catalog["images"] as? [[String: Any]] else {
        throw WidgetAssetTestError.failure("the app icon catalog has no images")
    }
    let defaultIcons = images.filter { image in
        let isiOS = image["platform"] as? String == "ios" || image["idiom"] as? String == "ios-marketing"
        let appearances = image["appearances"] as? [[String: String]] ?? []
        return isiOS && image["size"] as? String == "1024x1024" && appearances.isEmpty
    }
    try expect(!defaultIcons.isEmpty, "the default 1024x1024 iOS App Store icon is missing")
    // Apple rejects an alpha channel in the default App Store icon, even when
    // every pixel is opaque. Dark appearance icons intentionally support alpha.
    for entry in defaultIcons {
        guard let filename = entry["filename"] as? String else {
            throw WidgetAssetTestError.failure("the default iOS App Store icon has no filename")
        }
        let url = iconFolder.appendingPathComponent(filename)
        let png = try Data(contentsOf: url)
        try expect(
            png.count >= 33 && Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
            "\(filename): the App Store icon must be a readable PNG"
        )
        try expect(
            png[25] != 4 && png[25] != 6,
            "\(filename): PNG color type \(png[25]) encodes an alpha channel; App Store upload will reject it"
        )
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WidgetAssetTestError.failure("\(filename): ImageIO cannot decode the App Store icon")
        }
        try expect(image.width == 1024 && image.height == 1024, "\(filename): App Store icon must be 1024x1024")
        try expect(
            [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo),
            "\(filename): the decoded default App Store icon has alpha or palette transparency"
        )
    }
}

@main
private enum WidgetAssetCatalogTestRunner {
    static func main() throws {
        try testEveryProviderLogoIsInBothCatalogs()
        try testEveryAppLogoSetIsInTheWidget()
        try testTheWidgetTargetBundlesItsCatalog()
        try testDefaultIOSAppStoreIconHasNoAlphaChannel()
        print("Widget asset catalog tests passed")
    }
}
