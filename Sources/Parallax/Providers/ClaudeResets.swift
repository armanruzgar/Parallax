import CryptoKit
import Foundation
import CoreFoundation

/// Read-only reset availability using the account's existing CLI login.
enum ClaudeResets {
    static func keychainService(configFolder: URL) -> String {
        let path = configFolder.path.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash
    }

    static func keychainAccount(_ user: String = NSUserName()) -> String {
        user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil ? user : "claude-code-user"
    }

    static func accessToken(fromCredentials data: Data, now: Date) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expiry = oauth["expiresAt"] {
            guard let number = expiry as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue / 1000 > now.timeIntervalSince1970 else { return nil }
        }
        return token
    }

    static func parse(_ data: Data, now: Date) -> [LimitReset]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let reset = object["cedar_ember"] as? [String: Any],
              let eligible = reset["eligible"] as? NSNumber,
              CFGetTypeID(eligible) == CFBooleanGetTypeID(), eligible.boolValue else { return [] }
        var grouped: [String: LimitReset] = [:]
        for grant in reset["grants"] as? [[String: Any]] ?? [] {
            guard let number = grant["resets_left"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let left = Int(number.stringValue), left >= 0,
                  grant["paused"] as? Bool != true,
                  left > 0 || grant["usable_now"] as? Bool == true else { continue }
            let expiry = (grant["ends_at"] as? String).flatMap(RenewalDate.parse)
            if let expiry, expiry <= now { continue }
            let kind: String
            if grant["gives_back_weekly"] as? Bool == true { kind = "Fable reset" }
            else {
                switch grant["type"] as? String {
                case "session": kind = "5-hour reset"
                case "weekly": kind = "weekly reset"
                case "full": kind = "full reset"
                default:
                    let clears = grant["clears"] as? [String] ?? []
                    kind = !clears.isEmpty && clears.allSatisfy { $0 == "five_hour" } ? "5-hour reset"
                        : !clears.isEmpty && !clears.contains("five_hour") ? "weekly reset" : "full reset"
                }
            }
            let previous = grouped[kind]
            let count = (previous?.count ?? 0).addingReportingOverflow(max(left, 1))
            grouped[kind] = LimitReset(kind: kind, count: count.overflow ? Int.max : count.partialValue,
                                       expiresAt: [previous?.expiresAt, expiry].compactMap { $0 }.min())
        }
        return ["5-hour reset", "weekly reset", "Fable reset", "full reset"].compactMap { grouped[$0] }
    }

    static func read(configFolder: URL) async -> [LimitReset]? {
        do {
            let now = Date()
            let credentials = try? await ProviderCLI.run(executable: URL(fileURLWithPath: "/usr/bin/security"),
                ["find-generic-password", "-a", keychainAccount(), "-s", keychainService(configFolder: configFolder), "-w"],
                environment: [:], timeout: 10)
            try Task.checkCancellation()
            let data: Data
            if let credentials, credentials.status == 0 { data = credentials.stdout }
            else { data = try Data(contentsOf: configFolder.appendingPathComponent(".credentials.json")) }
            guard let token = accessToken(fromCredentials: data, now: now),
                  let url = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 15
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (body, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parse(body, now: Date())
        } catch { return nil }
    }
}
