import Foundation

private enum TestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private func expect(_ condition: Bool, _ label: String) throws {
    guard condition else {
        throw TestError.failure(label)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else {
        throw TestError.failure("\(label): expected \(expected), got \(actual)")
    }
}

private func chooser(_ url: String, leaving: String? = "https://www.kimi.ai/") -> String? {
    SignInAccountChooser.url(
        forcingChoiceIn: URL(string: url)!,
        leaving: leaving.map { URL(string: $0)! }
    )?.absoluteString
}

// MARK: - Account chooser

/// Kimi's own request: no prompt, so Google reused the only account it knew.
private func testGoogleAuthorizationGetsTheChooser() throws {
    let kimi = "https://accounts.google.com/o/oauth2/v2/auth?client_id=abc.apps.googleusercontent.com"
        + "&redirect_uri=https%3A%2F%2Fwww.kimi.ai/google-callback&response_type=id_token"
        + "&scope=email%20profile&nonce=a%2Bb%2Fc"
    try expectEqual(chooser(kimi), kimi + "&prompt=select_account", "Google v2 authorization")

    let legacy = "https://accounts.google.com/o/oauth2/auth?client_id=abc&scope=email+profile"
    try expectEqual(chooser(legacy), legacy + "&prompt=select_account", "Google v1 authorization")
}

private func testGitHubAuthorizationGetsTheChooser() throws {
    let workOS = "https://github.com/login/oauth/authorize?allow_signup=true&client_id=Ov23li"
        + "&redirect_uri=https%3A%2F%2Fauth.workos.com%2Fsso%2Foauth%2Fgithub%2Fcallback"
        + "&scope=user%3Aemail&state=eyJ%2B%2F%3D"
    try expectEqual(
        chooser(workOS, leaving: "https://signin.ollama.com/"),
        workOS + "&prompt=select_account",
        "GitHub authorization, query kept byte for byte"
    )
}

private func testNewPopupGetsTheChooser() throws {
    try expectEqual(
        chooser("https://accounts.google.com/o/oauth2/v2/auth?client_id=abc", leaving: nil),
        "https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&prompt=select_account",
        "a popup's first page has nothing committed yet"
    )
    try expectEqual(
        chooser("https://accounts.google.com/o/oauth2/v2/auth", leaving: nil),
        "https://accounts.google.com/o/oauth2/v2/auth?prompt=select_account",
        "no query at all"
    )
}

private func testSitePromptsAreLeftAlone() throws {
    for prompt in ["consent", "none", "select_account", "select_account%20consent", ""] {
        try expectEqual(
            chooser("https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&prompt=\(prompt)"),
            nil,
            "explicit prompt=\(prompt)"
        )
    }
    try expectEqual(
        chooser("https://accounts.google.com/o/oauth2/auth?client_id=abc&approval_prompt=force"),
        nil,
        "Google rejects prompt next to approval_prompt"
    )
    try expectEqual(
        chooser("https://github.com/login/oauth/authorize?client_id=abc&prompt=select_account"),
        nil,
        "GitHub request already asking"
    )
}

/// GitHub returns to its authorize endpoint once an account is picked; forcing
/// the chooser again from its own pages would loop.
private func testProviderPagesAreNotForcedAgain() throws {
    try expectEqual(
        chooser("https://github.com/login/oauth/authorize?client_id=abc", leaving: "https://github.com/login/oauth/select_account"),
        nil,
        "from GitHub's own page"
    )
    try expectEqual(
        chooser("https://accounts.google.com/o/oauth2/v2/auth?client_id=abc", leaving: "https://Accounts.Google.com/v3/signin/identifier"),
        nil,
        "from Google's own page, whatever the case"
    )
}

private func testOtherRequestsAreLeftAlone() throws {
    for url in [
        "https://accounts.google.com/gsi/select?client_id=abc",
        "https://accounts.google.com/signin/oauth/consent?authuser=0",
        "https://accounts.google.com/v3/signin/identifier?client_id=abc",
        "https://github.com/login?return_to=%2Flogin%2Foauth%2Fauthorize",
        "https://github.com/login/oauth/access_token?code=abc",
        "https://api.workos.com/user_management/authorize?provider=GitHubOAuth",
        "https://auth.mistral.ai/self-service/methods/oidc/callback/google",
        "http://accounts.google.com/o/oauth2/v2/auth?client_id=abc",
        "https://accounts.google.com.evil.example/o/oauth2/v2/auth?client_id=abc",
        "https://gist.github.com/login/oauth/authorize?client_id=abc"
    ] {
        try expectEqual(chooser(url), nil, url)
    }
}

private func testProviderHostMatchIgnoresCase() throws {
    try expectEqual(
        chooser("https://Accounts.Google.com/o/oauth2/v2/auth?client_id=abc"),
        "https://Accounts.Google.com/o/oauth2/v2/auth?client_id=abc&prompt=select_account",
        "hosts are case-insensitive"
    )
}

// MARK: - Popup layout

private func testRequestedSizeNeedsBothDimensions() throws {
    try expectEqual(
        SignInPopupLayout.requestedSize(width: 500, height: 600),
        CGSize(width: 500, height: 600),
        "window.open width and height"
    )
    try expectEqual(SignInPopupLayout.requestedSize(width: 500, height: nil), nil, "height missing")
    try expectEqual(SignInPopupLayout.requestedSize(width: nil, height: nil), nil, "no features")
    try expectEqual(SignInPopupLayout.requestedSize(width: 0, height: 600), nil, "zero width")
}

private func testRequestedPopupIsCentredAndClamped() throws {
    let container = CGSize(width: 780, height: 600)
    // Kimi asks for 500x600: the width fits, the height (plus title bar) is
    // clamped to what the importer has.
    try expectEqual(
        SignInPopupLayout.frame(requested: CGSize(width: 500, height: 600), depth: 0, in: container),
        CGRect(x: 140, y: 16, width: 500, height: 568),
        "Kimi's popup"
    )
    try expectEqual(
        SignInPopupLayout.frame(requested: CGSize(width: 420, height: 300), depth: 0, in: container),
        CGRect(x: 180, y: 136, width: 420, height: 328),
        "a small popup sits centred"
    )
}

private func testUnsizedPopupFillsTheImporter() throws {
    try expectEqual(
        SignInPopupLayout.frame(requested: nil, depth: 0, in: CGSize(width: 780, height: 600)),
        CGRect(x: 16, y: 16, width: 748, height: 568),
        "a target=_blank page opens full size"
    )
}

private func testNestedPopupsStepDownAndRight() throws {
    let container = CGSize(width: 780, height: 600)
    try expectEqual(
        SignInPopupLayout.frame(requested: CGSize(width: 360, height: 240), depth: 1, in: container),
        CGRect(x: 234, y: 190, width: 360, height: 268),
        "a nested popup cascades from centre"
    )
    try expectEqual(
        SignInPopupLayout.frame(requested: nil, depth: 1, in: container),
        CGRect(x: 40, y: 40, width: 724, height: 544),
        "a nested full-size popup still shows the one beneath"
    )
}

private func testPopupsStayInsideTheMargins() throws {
    let margin = SignInPopupLayout.margin
    for container in [CGSize(width: 760, height: 560), CGSize(width: 1020, height: 780), CGSize(width: 320, height: 480)] {
        for requested in [nil, CGSize(width: 500, height: 600), CGSize(width: 2000, height: 2000), CGSize(width: 10, height: 10)] {
            for depth in 0..<6 {
                let frame = SignInPopupLayout.frame(requested: requested, depth: depth, in: container)
                let label = "\(requested.map { "\($0)" } ?? "unsized") at depth \(depth) in \(container)"
                try expect(frame.width >= 0 && frame.height >= 0, "\(label): non-negative size")
                try expect(frame.minX >= margin && frame.minY >= margin, "\(label): clear of top-left margin")
                try expect(frame.maxX <= container.width - margin, "\(label): clear of right margin")
                try expect(frame.maxY <= container.height - margin, "\(label): clear of bottom margin")
            }
        }
    }
}

// MARK: - Runner

@main
private enum SignInBrowserTestRunner {
    static func main() throws {
        try testGoogleAuthorizationGetsTheChooser()
        try testGitHubAuthorizationGetsTheChooser()
        try testNewPopupGetsTheChooser()
        try testSitePromptsAreLeftAlone()
        try testProviderPagesAreNotForcedAgain()
        try testOtherRequestsAreLeftAlone()
        try testProviderHostMatchIgnoresCase()
        try testRequestedSizeNeedsBothDimensions()
        try testRequestedPopupIsCentredAndClamped()
        try testUnsizedPopupFillsTheImporter()
        try testNestedPopupsStepDownAndRight()
        try testPopupsStayInsideTheMargins()
        print("Sign-in browser tests passed")
    }
}
