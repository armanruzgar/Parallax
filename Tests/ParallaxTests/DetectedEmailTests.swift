import XCTest
@testable import Parallax

final class DetectedEmailTests: ChatFixture {
    private func writeConfig(_ folders: ClaudeChats.SpaceFolders, account: [String: Any]?) throws {
        try FileManager.default.createDirectory(at: folders.config, withIntermediateDirectories: true)
        var object: [String: Any] = ["userID": "u1"]
        if let account { object["oauthAccount"] = account }
        try JSONSerialization.data(withJSONObject: object).write(to: folders.config.appendingPathComponent(".claude.json"))
    }

    func testSignedInEmailComesFromTheSpaceConfig() throws {
        let folders = space("A")
        XCTAssertNil(ClaudeProvider.signedInEmail(configFolder: folders.config))
        try writeConfig(folders, account: nil)
        XCTAssertNil(ClaudeProvider.signedInEmail(configFolder: folders.config))
        try writeConfig(folders, account: ["emailAddress": "  "])
        XCTAssertNil(ClaudeProvider.signedInEmail(configFolder: folders.config))
        try writeConfig(folders, account: ["emailAddress": " a@example.com \n", "displayName": "A"])
        XCTAssertEqual(ClaudeProvider.signedInEmail(configFolder: folders.config), "a@example.com")
    }

    @MainActor
    func testSpaceUsageFollowsTheSignedInAccountAndTrackingAddsIt() async throws {
        let model = AppModel(support: root.appendingPathComponent("support"), defaults: MemoryDefaults(), startServices: false, hooks: testHooks())
        var app = ManagedApp(name: "Claude", path: "/Applications/Claude.app", bundleID: "com.anthropic.claudefordesktop", kind: .claude, dataFolder: root.path)
        let signedIn = Space(name: "Signed in", folder: root.appendingPathComponent("one").path, email: "typed@example.com")
        let typedOnly = Space(name: "Typed", folder: root.appendingPathComponent("two").path, email: "typed@example.com")
        let fresh = Space(name: "Fresh", folder: root.appendingPathComponent("three").path)
        app.spaces = [signedIn, typedOnly, fresh]
        model.apps = [app]
        try writeConfig(ClaudeChats.folders(for: signedIn), account: ["emailAddress": "Real@Example.com"])

        model.refreshDetectedEmails()
        XCTAssertEqual(model.email(for: signedIn), "Real@Example.com", "What the space is signed in to wins over the typed email")
        XCTAssertEqual(model.email(for: typedOnly), "typed@example.com")
        XCTAssertEqual(model.email(for: fresh), "")
        XCTAssertNil(model.account(for: signedIn, in: app))

        model.signInStatus = { _ in ProviderStatus(email: "real@example.com", plan: "Max", windows: [UsageWindow(title: "Session", percent: 18)]) }
        await model.addAccount(provider: .claude, label: signedIn.name, email: model.email(for: signedIn))
        let account = try XCTUnwrap(model.account(for: signedIn, in: app))
        XCTAssertEqual(account.label, "Signed in")
        XCTAssertEqual(account.email, "real@example.com")
        XCTAssertTrue(account.signedIn)
        XCTAssertEqual(account.headline(at: Date())?.percent, 18)
        XCTAssertNil(model.account(for: typedOnly, in: app))

        // Signing in to another account inside the space moves its usage to that account.
        try writeConfig(ClaudeChats.folders(for: signedIn), account: ["emailAddress": "other@example.com"])
        model.refreshDetectedEmails()
        XCTAssertNil(model.account(for: signedIn, in: app))
        XCTAssertEqual(model.email(for: signedIn), "other@example.com")

        // A failed sign-in keeps the expected email so the row still points at the account.
        model.signInStatus = { _ in throw ProviderError.failed("Claude sign-in didn't finish.") }
        await model.addAccount(provider: .claude, label: fresh.name, email: "fresh@example.com")
        let pending = try XCTUnwrap(model.account(forEmail: "fresh@example.com", provider: .claude))
        XCTAssertFalse(pending.signedIn)
        XCTAssertEqual(pending.lastError, "Claude sign-in didn't finish.")
    }
}
