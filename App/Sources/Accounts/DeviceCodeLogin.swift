import Foundation

/// Microsoft device-code sign-in: the app shows a short code, you enter it at
/// microsoft.com/link (on this phone or any other device) and sign in there.
/// No redirect URI involved, and the password never touches ZMF.
struct DeviceCodeChallenge: Decodable, Equatable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int
    let message: String?
}

enum DeviceCodeLogin {
    private static let base = "https://login.microsoftonline.com/consumers/oauth2/v2.0"

    static func start(clientID: String) async throws -> DeviceCodeChallenge {
        guard !clientID.isEmpty else { throw AuthError.missingClientID }
        let data = try await HTTP.postForm(URL(string: "\(base)/devicecode")!,
                                           fields: ["client_id": clientID, "scope": MicrosoftAuthenticator.scope])
        return try JSONDecoder().decode(DeviceCodeChallenge.self, from: data)
    }

    /// Polls until the user finishes (or the code expires / is declined).
    static func waitForToken(clientID: String, challenge: DeviceCodeChallenge) async throws -> MicrosoftToken {
        var interval = UInt64(max(challenge.interval, 2))
        let deadline = Date().addingTimeInterval(TimeInterval(challenge.expires_in))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
            do {
                return try await MicrosoftToken.redeem(fields: [
                    "client_id": clientID,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": challenge.device_code,
                ])
            } catch let e as HTTPError {
                switch pollError(e.body) {
                case "authorization_pending": continue
                case "slow_down": interval += 5
                case "authorization_declined": throw AuthError.cancelled
                case "expired_token": throw AuthError.xbox("The sign-in code expired. Start again.")
                default: throw e
                }
            }
        }
        throw AuthError.xbox("The sign-in code expired. Start again.")
    }

    static func pollError(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["error"] as? String
    }
}
