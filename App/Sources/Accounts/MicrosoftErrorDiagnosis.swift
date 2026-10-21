import Foundation

/// Turns Microsoft identity platform errors (AADSTS codes) into the exact
/// setting to change in the Azure / Entra app registration.
enum MicrosoftErrorDiagnosis {
    struct Diagnosis: Equatable {
        let code: String       // e.g. "AADSTS700016" or the OAuth error name
        let fix: String
        let raw: String        // Microsoft's own first line, for reference
    }

    static let accountTypesFix = """
    Your app registration does not allow personal Microsoft accounts (Minecraft accounts are personal accounts). \
    In portal.azure.com › App registrations › your app › Manifest, set "signInAudience" to "AzureADandPersonalMicrosoftAccount" and Save. \
    (Or: Authentication › Supported account types › "Accounts in any organizational directory and personal Microsoft accounts".)
    """
    static let publicClientFix = """
    Your app is set up as a confidential (web) app. In portal.azure.com › App registrations › your app › Authentication: \
    turn "Allow public client flows" to Yes and Save. Do not add a client secret — ZMF is a public client.
    """
    static let redirectFix = """
    The redirect URI is missing. In App registrations › your app › Authentication › Add a platform › \
    "Mobile and desktop applications" › Custom redirect URI: zmflauncher://auth › Configure.
    """
    static let wrongIDFix = """
    Microsoft can't find an app with this ID. Copy the "Application (client) ID" from the app's Overview page \
    (not the Object ID or Directory/tenant ID) and paste it again.
    """

    /// Parses an error body (JSON from the token/devicecode endpoints) or a
    /// redirect error description.
    static func diagnose(body: String) -> Diagnosis? {
        var error = ""
        var description = body
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            error = obj["error"] as? String ?? ""
            description = obj["error_description"] as? String ?? ""
        }
        let code = description.range(of: #"AADSTS\d+"#, options: .regularExpression).map { String(description[$0]) } ?? error
        let raw = description.components(separatedBy: CharacterSet(charactersIn: "\r\n")).first ?? description
        let lower = description.lowercased()

        let fix: String
        switch code {
        case "AADSTS700016", "AADSTS90130", "AADSTS50194", "AADSTS50020", "AADSTS9002331":
            // 700016 = not found "in the directory 'Microsoft Accounts'": usually the
            // account type, sometimes a wrong ID. Point at both.
            fix = code == "AADSTS700016" ? accountTypesFix + "\n\nIf that is already set: " + wrongIDFix : accountTypesFix
        case "AADSTS7000218", "AADSTS700025", "AADSTS70002":
            fix = publicClientFix
        case "AADSTS50011", "AADSTS500113":
            fix = redirectFix
        case "AADSTS90014", "AADSTS900144":
            fix = "Microsoft rejected the request format. Please report this with the code shown."
        case "AADSTS70000":
            fix = "Microsoft rejected the requested permission. In API permissions, no extra permissions are needed — remove custom ones, Save, and try again."
        default:
            if error == "unauthorized_client" || lower.contains("not enabled for consumers") {
                fix = accountTypesFix
            } else if error == "invalid_client" || lower.contains("client_secret") || lower.contains("client_assertion") {
                fix = publicClientFix
            } else if lower.contains("redirect") {
                fix = redirectFix
            } else if error.isEmpty && code.isEmpty {
                return nil
            } else {
                fix = "Microsoft returned \(code.isEmpty ? error : code). Check the app registration settings listed under Advanced."
            }
        }
        return Diagnosis(code: code.isEmpty ? error : code, fix: fix, raw: raw)
    }

    static func message(step: String, _ d: Diagnosis) -> String {
        "\(step) failed — \(d.code)\n\n\(d.fix)\n\nMicrosoft said: \(d.raw.prefix(240))"
    }

    /// Checks an app ID without signing anyone in: asks Microsoft for a
    /// device code (needs the ID to exist and accept personal accounts), then
    /// polls once (needs public client flows; "authorization_pending" = OK).
    static func check(clientID: String) async -> String {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else {
            return "That doesn't look like an app ID. It should be a GUID like 00000000-0000-0000-0000-000000000000 (Overview › Application (client) ID)."
        }
        let challenge: DeviceCodeChallenge
        do {
            challenge = try await DeviceCodeLogin.start(clientID: id)
        } catch {
            return AuthError.explain(error)
        }
        do {
            _ = try await MicrosoftToken.redeem(fields: [
                "client_id": id,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": challenge.device_code,
            ])
        } catch let e as HTTPError {
            if DeviceCodeLogin.pollError(e.body) == "authorization_pending" {
                return "✅ Microsoft accepts this app ID for personal accounts and public client sign-in. If sign-in still stops at step 3 (Minecraft, HTTP 403), the ID is waiting for Microsoft's Minecraft approval (aka.ms/mce-reviewappid)."
            }
            return AuthError.explain(e)
        } catch {
            return AuthError.explain(error)
        }
        return "✅ App ID accepted."
    }
}
