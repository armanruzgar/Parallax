import XCTest
@testable import Parallax

final class SidebarTests: ChatFixture {
    private func config(_ space: ClaudeChats.SpaceFolders) -> URL {
        space.sessions.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.json")
    }

    private func writeConfig(_ space: ClaudeChats.SpaceFolders, prefs: [String: Any], modified: Date, extra: [String: Any] = [:]) throws {
        var preferences: [String: Any] = ["sidebarMode": "epitaxy", "epitaxyPrefs": prefs]
        preferences.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: ["preferences": preferences, "keep": "me"]).write(to: config(space))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: config(space).path)
    }

    private func writePresets(_ space: ClaudeChats.SpaceFolders, account: String, _ presets: [(id: String, cwd: String)]) throws {
        let list = presets.map { ["id": $0.id, "name": "x", "target": ["kind": "local", "cwd": $0.cwd]] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["byAccount": [account: ["presets": list]]])
            .write(to: space.sessions.deletingLastPathComponent().appendingPathComponent("ccd-session-presets.json"))
    }

    private func prefs(_ space: ClaudeChats.SpaceFolders) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config(space))) as? [String: Any])
        return try XCTUnwrap((object["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])
    }

    func testLayoutFromTheLastUsedSpaceIsCopiedUnderTheTargetAccount() throws {
        let a = space("A"), b = space("B")
        _ = try namespace(a, account: "acctA", org: "orgA")
        _ = try namespace(b, account: "acctB", org: "orgB")
        let group = ["groups": [["id": "cg-1", "name": "payloop"]], "assignments": ["code:" + chatID: "cg-1"],
                     "order": ["cg-1": ["code:" + chatID]]] as [String: Any]
        try writePresets(a, account: "acctA", [("pa", "/work/project"), ("pb", "/work/other")])
        try writePresets(b, account: "acctB", [("pz", "/work/project")])
        try writeConfig(a, prefs: [
            "dframe-group-scopes": ["acctA/orgA": group],
            "dframe-code-sections": ["acctA/orgA": ["sections": [["id": "cg-1", "kind": "manual"]]]],
            "dframe-local-slice": ["pinnedOrder": ["code:" + chatID]],
            "starred-local-code-sessions": [chatID],
            "code-projects-order.acctA": ["preset::pb", "preset::pa", "38st/repo", "preset::gone"],
        ], modified: Date(timeIntervalSince1970: 2_000))
        try writeConfig(b, prefs: [
            "dframe-group-scopes": ["acctB/orgB": ["groups": []], "other/scope": ["groups": ["kept"]]],
            "fastMode": true,
        ], modified: Date(timeIntervalSince1970: 1_000), extra: ["coworkWebSearchEnabled": true])

        XCTAssertNil(ClaudeChats.carriedLayout(to: a, spaces: [a, b]), "The newest layout is never overwritten by an older one")
        XCTAssertTrue(try ClaudeChats.carryLayout(to: b, spaces: [a, b], backups: backups))
        let carried = try prefs(b)
        let scopes = try XCTUnwrap(carried["dframe-group-scopes"] as? [String: Any])
        XCTAssertEqual(scopes["acctB/orgB"] as? NSDictionary, group as NSDictionary)
        XCTAssertEqual(scopes["other/scope"] as? NSDictionary, ["groups": ["kept"]] as NSDictionary)
        XCTAssertNotNil((carried["dframe-code-sections"] as? [String: Any])?["acctB/orgB"])
        XCTAssertEqual(carried["starred-local-code-sessions"] as? [String], [chatID])
        XCTAssertEqual(carried["code-projects-order.acctB"] as? [String], ["/work/other", "preset::pz", "38st/repo"])
        XCTAssertEqual(carried["fastMode"] as? Bool, true, "Other preferences stay")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config(b))) as? [String: Any])
        XCTAssertEqual(object["keep"] as? String, "me")
        XCTAssertEqual((object["preferences"] as? [String: Any])?["coworkWebSearchEnabled"] as? Bool, true)
        XCTAssertEqual(try savedFiles().map(\.lastPathComponent), ["claude_desktop_config.json"])
        XCTAssertNil(ClaudeChats.carriedLayout(to: b, spaces: [a, b]), "Once copied, there is nothing left to carry")
    }

    func testSyncCarriesTheLayout() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b)
        try writeConfig(a, prefs: ["dframe-local-slice": ["pinnedOrder": ["code:" + chatID]]], modified: Date(timeIntervalSince1970: 2_000))
        try writeConfig(b, prefs: [:], modified: Date(timeIntervalSince1970: 1_000))
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.layoutCarried)
        XCTAssertEqual((try prefs(b)["dframe-local-slice"] as? [String: Any])?["pinnedOrder"] as? [String], ["code:" + chatID])
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
