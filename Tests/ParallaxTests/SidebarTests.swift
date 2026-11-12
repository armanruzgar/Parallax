import XCTest
@testable import Parallax

final class SidebarTests: ChatFixture {
    func testSyncCarriesChatsWithoutChangingSidebarLayout() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b, account: "acctB", org: "orgB")
        for (space, scope, group, modified) in [(a, "acct/org", "new", 2_000.0), (b, "acctB/orgB", "old", 1_000.0)] {
            let prefs: [String: Any] = [
                "dframe-group-scopes": [scope: ["groups": [["id": group, "name": group]]]],
                "dframe-code-sections": [scope: ["sections": [["id": group, "kind": "manual"]]]],
            ]
            let config = space.sessions.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.json")
            try JSONSerialization.data(withJSONObject: ["preferences": ["epitaxyPrefs": prefs]]).write(to: config)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: config.path)
        }
        let config = b.sessions.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.json")
        let before = try Data(contentsOf: config)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)

        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(ClaudeChats.scan([b]).map(\.id), [chatID])
        XCTAssertEqual(try ClaudeChats.normalizedTranscript(Data(contentsOf: native(b)), cwds: [cwd]),
                       try ClaudeChats.normalizedTranscript(Data(contentsOf: native(a)), cwds: [cwd]))
        XCTAssertEqual(try Data(contentsOf: config), before)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertFalse(backupNames.contains { $0.contains("-sidebar-") })
    }

    private func writeConfig(_ space: ClaudeChats.SpaceFolders, prefs: [String: Any], modified: Double) throws {
        let url = ClaudeChats.desktopConfig(space)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = ["coworkUserFilesPath": "/kept", "preferences": ["sidebarMode": "epitaxy", "epitaxyPrefs": prefs]]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
    }

    private func prefs(_ space: ClaudeChats.SpaceFolders) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeChats.desktopConfig(space))) as? [String: Any])
        XCTAssertEqual(object["coworkUserFilesPath"] as? String, "/kept")
        XCTAssertEqual((object["preferences"] as? [String: Any])?["sidebarMode"] as? String, "epitaxy")
        return try XCTUnwrap((object["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])
    }

    private func groupScope(_ space: ClaudeChats.SpaceFolders, _ account: String) throws -> [String: Any] {
        try XCTUnwrap((prefs(space)["dframe-group-scopes"] as? [String: Any])?[account] as? [String: Any])
    }

    private func filed(_ chat: String, in group: String, name: String = "FLOW") -> [String: Any] {
        ["groups": [["id": group, "name": name, "mode": "code"]], "assignments": ["code:" + chat: group], "order": [group: ["code:" + chat]]]
    }

    private func sidebarBackups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).filter { $0.contains("-sidebar-") }
    }

    func testCarriedChatJoinsTheGroupWithTheSameName() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b, account: "acctB", org: "orgB")
        try writeConfig(a, prefs: ["dframe-group-scopes": ["acct/org": filed(chatID, in: "cg-a")]], modified: 2_000)
        // B's own FLOW has no chats yet, so Claude lists it only as a sidebar section.
        let sections = ["acctB/orgB": ["sections": [["id": "sessions", "kind": "sessions"], ["id": "cg-b", "kind": "manual", "name": " flow"]]]]
        try writeConfig(b, prefs: [
            "dframe-group-scopes": ["acctB/orgB": filed("local_other", in: "cg-other", name: "other"), "old/scope": ["groups": []]],
            "dframe-code-sections": sections,
            "fastMode": true,
        ], modified: 1_000)
        let before = try Data(contentsOf: ClaudeChats.desktopConfig(b))

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)

        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(result.grouped, 1)
        let scope = try groupScope(b, "acctB/orgB")
        XCTAssertEqual(scope["assignments"] as? NSDictionary,
                       ["code:local_other": "cg-other", "code:" + chatID: "cg-b"] as NSDictionary)
        XCTAssertEqual(scope["order"] as? NSDictionary,
                       ["cg-other": ["code:local_other"], "cg-b": ["code:" + chatID]] as NSDictionary)
        XCTAssertEqual(scope["groups"] as? NSArray, [["id": "cg-other", "name": "other", "mode": "code"],
                                                     ["id": "cg-b", "name": " flow", "mode": "code"]] as NSArray)
        let carried = try prefs(b)
        XCTAssertEqual(carried["fastMode"] as? Bool, true)
        XCTAssertEqual(carried["dframe-code-sections"] as? NSDictionary, sections as NSDictionary)
        XCTAssertEqual((carried["dframe-group-scopes"] as? [String: Any])?["old/scope"] as? NSDictionary, ["groups": []] as NSDictionary)
        let saved = sidebarBackups()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups.appendingPathComponent(saved[0]).appendingPathComponent("claude_desktop_config.json")), before)

        let again = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(again.issues.isEmpty, "\(again.issues)")
        XCTAssertEqual(again.grouped, 0)
        XCTAssertEqual(sidebarBackups().count, 1)
    }

    func testGroupComesFromTheSpaceUsedLast() throws {
        let a = space("A"), b = space("B"), c = space("C")
        for space in [a, b, c] { try writeNativeChat(in: space, lines: [line("user", "one")], lastActivity: 100) }
        try writeConfig(a, prefs: ["dframe-group-scopes": ["acct/org": filed(chatID, in: "cg-a")]], modified: 1_000)
        try writeConfig(b, prefs: ["dframe-code-sections": ["acct/org": ["sections": [["id": "cg-b", "kind": "manual", "name": "FLOW"]]]]],
                        modified: 500)
        try writeConfig(c, prefs: ["dframe-code-sections": ["acct/org": ["sections": [["id": "cg-c", "kind": "manual", "name": "FLOW"]]]]],
                        modified: 3_000)

        var result = ClaudeChats.syncAll(to: b, spaces: [a, b, c], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 0)
        XCTAssertEqual(result.grouped, 0, "The space used last keeps the chat outside its groups")
        XCTAssertNil(try prefs(b)["dframe-group-scopes"])

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                                              ofItemAtPath: ClaudeChats.desktopConfig(c).path)
        result = ClaudeChats.syncAll(to: b, spaces: [a, b, c], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 0, "Filing a chat needs no new messages")
        XCTAssertEqual(result.grouped, 1)
        XCTAssertEqual(try groupScope(b, "acct/org")["assignments"] as? NSDictionary, ["code:" + chatID: "cg-b"] as NSDictionary)
    }

    func testTargetGroupsAreNeitherChangedNorMade() throws {
        let a = space("A"), b = space("B")
        for space in [a, b] { try writeNativeChat(in: space, lines: [line("user", "one")], lastActivity: 100) }
        try writeConfig(a, prefs: ["dframe-group-scopes": ["acct/org": filed(chatID, in: "cg-a")]], modified: 2_000)
        // Claude keeps its own choice of group, so a chat filed elsewhere in B is left there.
        var own = filed(chatID, in: "cg-mine", name: "mine")
        own["groups"] = [["id": "cg-b", "name": "FLOW", "mode": "code"], ["id": "cg-mine", "name": "mine", "mode": "code"]]
        try writeConfig(b, prefs: ["dframe-group-scopes": ["acct/org": own]], modified: 1_000)
        let kept = try Data(contentsOf: ClaudeChats.desktopConfig(b))
        var result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.grouped, 0)
        XCTAssertEqual(try Data(contentsOf: ClaudeChats.desktopConfig(b)), kept)

        // B has no group with that name, and groups belong to the account, so none is made.
        try writeConfig(b, prefs: ["dframe-code-sections": ["acct/org": ["sections": [["id": "cg-mine", "kind": "manual", "name": "mine"]]]]],
                        modified: 1_000)
        let unchanged = try Data(contentsOf: ClaudeChats.desktopConfig(b))
        result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.grouped, 0)
        XCTAssertEqual(try Data(contentsOf: ClaudeChats.desktopConfig(b)), unchanged)
        XCTAssertTrue(sidebarBackups().isEmpty)
    }

    func testActivityTimeCatchesUpWhenMessagesMatch() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 500)
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 100)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual((try record(b)["lastActivityAt"] as? NSNumber)?.doubleValue, 500)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
        XCTAssertEqual(try transfer(to: a, spaces: [a, b]).kind, .upToDate)
    }

    func testTurnTimeCatchesUpWhenMessagesMatch() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 500, extra: ["lastTurnEdgeAt": 900])
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 500)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 1)
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 900)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 500)
        XCTAssertNil(carried["lastFocusedAt"])
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
        XCTAssertEqual(try transfer(to: a, spaces: [a, b]).kind, .upToDate)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testActivityTimeRaisesStaleTargetTurnTime() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 600)
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 100, extra: ["lastTurnEdgeAt": 100])
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 600, "An existing turn key stays even when it matches activity")
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 600)
        XCTAssertEqual(try XCTUnwrap(ClaudeChats.scan([b]).first).sidebarOrderAt, 600)
    }

    func testActivityWithoutATurnDoesNotRaiseSidebarOrder() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 800, extra: ["lastTurnEdgeAt": 300])
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 300)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        let carried = try record(b)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 800)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 300)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
    }

    func testNewMessagesCarryTurnTime() throws {
        let a = space("A"), b = space("B")
        let messages = [line("user", "one"), line("assistant", "two")]
        try writeNativeChat(in: a, lines: messages, lastActivity: 650, extra: ["lastTurnEdgeAt": 700])
        try writeNativeChat(in: b, lines: [messages[0]], lastActivity: 100)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .update)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 1)
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 700)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 650)
        XCTAssertEqual(try ClaudeChats.normalizedTranscript(Data(contentsOf: native(b)), cwds: [cwd]),
                       try ClaudeChats.normalizedTranscript(Data(contentsOf: native(a)), cwds: [cwd]))
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
    }

    func testAddedChatCarriesTurnTime() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 650, extra: ["lastTurnEdgeAt": 700])
        _ = try namespace(b)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .add)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 1)
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 700)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 650)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
    }

    func testChatListUsesClaudeSidebarOrder() throws {
        let a = space("A")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100, extra: ["lastTurnEdgeAt": 900])
        try writeNativeChat(in: a, lines: [line("user", "two", sessionID: "second")], lastActivity: 800,
                            chatID: "local_second", cliSessionID: "second")
        try writeNativeChat(in: a, lines: [line("user", "three", sessionID: "third")], lastActivity: 1000,
                            chatID: "local_third", cliSessionID: "third", lastFocused: 2000, extra: ["lastTurnEdgeAt": 200])
        let chats = ClaudeChats.scan([a])
        XCTAssertEqual(chats.map(\.id), [chatID, "local_second", "local_third"])
        XCTAssertEqual(chats.map(\.sidebarOrderAt), [900, 800, 200])
        XCTAssertEqual(chats.map(\.sidebarOrder), [900.0, 800, 200].map { Date(timeIntervalSince1970: $0 / 1000) })
        XCTAssertEqual(chats[0].lastActivity, Date(timeIntervalSince1970: 0.1))
    }

    func testSidebarOrderIncludesTheTargetsCopy() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one"), line("assistant", "two")],
                            lastActivity: 650, extra: ["lastTurnEdgeAt": 700])
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 600, extra: ["lastTurnEdgeAt": 900])
        let prepared = try transfer(to: b, spaces: [a, b])
        XCTAssertEqual(prepared.kind, .update)
        XCTAssertEqual(prepared.source.spaceID, a.spaceID)
        XCTAssertEqual(prepared.sidebarOrderAt, 900)
        XCTAssertEqual(try XCTUnwrap(ClaudeChats.scan([a, b]).first).sidebarOrderAt, 900)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 900)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 650)
    }

    func testApplyKeepsDestinationTimesChangedAfterPrepare() throws {
        for kind in [ChatTransfer.Kind.updateMetadata, .update] {
            for hasTurn in [false, true] {
                let a = space("A-\(kind)-\(hasTurn)"), b = space("B-\(kind)-\(hasTurn)")
                let messages = [line("user", "one")] + (kind == .update ? [line("assistant", "two")] : [])
                try writeNativeChat(in: a, lines: messages, lastActivity: 500, lastFocused: 400, extra: ["lastTurnEdgeAt": 700])
                try writeNativeChat(in: b, lines: [messages[0]], lastActivity: 100, lastFocused: 100)
                let prepared = try transfer(to: b, spaces: [a, b])
                XCTAssertEqual(prepared.kind, kind)
                try editRecord(b) {
                    $0["lastActivityAt"] = 800
                    if hasTurn { $0["lastTurnEdgeAt"] = 900 }
                    $0["lastFocusedAt"] = 1000
                }
                try ClaudeChats.apply(prepared, backups: backups)
                let carried = try record(b)
                XCTAssertEqual(carried["lastActivityAt"] as? Double, 800)
                XCTAssertEqual(carried["lastFocusedAt"] as? Double, 1000)
                XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, hasTurn ? 900 : nil)
                XCTAssertEqual(try XCTUnwrap(ClaudeChats.scan([b]).first).sidebarOrderAt, hasTurn ? 900 : 800)
            }
        }
    }
}
