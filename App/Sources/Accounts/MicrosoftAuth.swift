import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// A signed-in Microsoft account with a Minecraft: Java Edition profile.
struct MinecraftAccount: Codable, Identifiable, Equatable {
    var id: String              // Minecraft profile UUID (no dashes)
    var username: String
    var xuid: String?
    var skinURL: URL?
    var skinVariant: String?
    var microsoftRefreshToken: String
    var minecraftAccessToken: String
    var minecraftTokenExpiry: Date
    var ownsJavaEdition: Bool
    var entitlements: [String]

    var needsRefresh: Bool { minecraftTokenExpiry.timeIntervalSinceNow < 300 }

    var dashedUUID: String {
        guard id.count == 32 else { return id }
        let s = Array(id)
        return [s[0..<8], s[8..<12], s[12..<16], s[16..<20], s[20..<32]].map { String($0) }.joined(separator: "-")
    }
}

enum AuthError: LocalizedError {
    case missingClientID
    case cancelled
    case noCode
    case stateMismatch
    case xbox(String)
    case noJavaProfile
    case notOwned

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "No Microsoft application (client) ID is configured. Register an Azure app with redirect URI zmflauncher://auth and enter its ID in Settings › Account, or set ZMF_MSA_CLIENT_ID for the build."
        case .cancelled: return "Sign-in was cancelled."
        case .noCode: return "Microsoft did not return an authorization code."
        case .stateMismatch: return "Sign-in response did not match the request (state mismatch)."
        case .xbox(let m): return m
        case .noJavaProfile: return "This Microsoft account has no Minecraft: Java Edition profile. Buy the game or create your profile at minecraft.net first."
        case .notOwned: return "This account does not own Minecraft: Java Edition."
        }
    }
}

/// Microsoft identity platform (authorization code + PKCE in the system
/// browser sheet — the launcher never sees the password) → Xbox Live → XSTS →
/// Minecraft services.
@MainActor
final class MicrosoftAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let redirectURI = "zmflauncher://auth"
    static let scope = "XboxLive.signin offline_access"
    private static let authorizeURL = "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize"

    private var session: ASWebAuthenticationSession?

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }

    // MARK: Interactive sign-in

    func signIn(clientID: String) async throws -> MinecraftAccount {
        guard !clientID.isEmpty else { throw AuthError.missingClientID }
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        var comps = URLComponents(string: Self.authorizeURL)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]
        let callback = try await present(url: comps.url!)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? ""
            throw AuthError.xbox("Microsoft sign-in error: \(err) \(desc)")
        }
        guard items.first(where: { $0.name == "state" })?.value == state else { throw AuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.noCode }

        let token = try await MicrosoftToken.redeem(fields: [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
            "scope": Self.scope,
        ])
        return try await MinecraftServices.login(microsoft: token)
    }

    private func present(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "zmflauncher") { callback, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: AuthError.noCode)
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { continuation.resume(throwing: AuthError.xbox("Could not open the Microsoft sign-in sheet.")) }
        }
    }

    // MARK: Refresh

    static func refresh(_ account: MinecraftAccount, clientID: String) async throws -> MinecraftAccount {
        guard !clientID.isEmpty else { throw AuthError.missingClientID }
        let token = try await MicrosoftToken.redeem(fields: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": account.microsoftRefreshToken,
            "scope": scope,
        ])
        return try await MinecraftServices.login(microsoft: token)
    }
}

enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct MicrosoftToken: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int

    static func redeem(fields: [String: String]) async throws -> MicrosoftToken {
        let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
        return try JSONDecoder().decode(MicrosoftToken.self, from: try await HTTP.postForm(url, fields: fields))
    }
}

/// Xbox Live and Minecraft services exchange.
enum MinecraftServices {
    private struct XboxResponse: Decodable {
        struct Claims: Decodable { let xui: [[String: String]] }
        let Token: String
        let DisplayClaims: Claims
    }
    private struct MinecraftLogin: Decodable { let access_token: String; let expires_in: Int }
    private struct Entitlements: Decodable { struct Item: Decodable { let name: String }; let items: [Item] }
    private struct Profile: Decodable {
        struct Skin: Decodable { let url: URL; let state: String; let variant: String? }
        let id: String
        let name: String
        let skins: [Skin]?
    }

    static func login(microsoft: MicrosoftToken) async throws -> MinecraftAccount {
        // 1. Xbox Live user token
        let xbl: XboxResponse = try await xbox(URL(string: "https://user.auth.xboxlive.com/user/authenticate")!, body: [
            "Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": "d=\(microsoft.access_token)"],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT",
        ])
        // 2. XSTS token for Minecraft services
        let xsts: XboxResponse = try await xbox(URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!, body: [
            "Properties": ["SandboxId": "RETAIL", "UserTokens": [xbl.Token]] as [String: Any],
            "RelyingParty": "rp://api.minecraftservices.com/",
            "TokenType": "JWT",
        ])
        guard let uhs = xsts.DisplayClaims.xui.first?["uhs"] else { throw AuthError.xbox("Xbox Live returned no user hash.") }
        let xuid = xsts.DisplayClaims.xui.first?["xid"]

        // 3. Minecraft access token
        let loginData: Data
        do {
            loginData = try await HTTP.postJSON(URL(string: "https://api.minecraftservices.com/authentication/login_with_xbox")!,
                                                body: ["identityToken": "XBL3.0 x=\(uhs);\(xsts.Token)"])
        } catch let e as HTTPError where e.status == 403 {
            throw AuthError.xbox("Minecraft services rejected this app's client ID (HTTP 403). New Azure app registrations must be approved by Microsoft for Minecraft access (aka.ms/mce-reviewappid).")
        }
        let mc = try JSONDecoder().decode(MinecraftLogin.self, from: loginData)
        let bearer = ["Authorization": "Bearer \(mc.access_token)"]

        // 4. Ownership and profile
        let ent = (try? await HTTP.getJSON(Entitlements.self, URL(string: "https://api.minecraftservices.com/entitlements/mcstore")!, headers: bearer))?.items.map(\.name) ?? []
        let profile: Profile
        do {
            profile = try await HTTP.getJSON(Profile.self, URL(string: "https://api.minecraftservices.com/minecraft/profile")!, headers: bearer)
        } catch let e as HTTPError where e.status == 404 {
            throw AuthError.noJavaProfile
        }
        // A Java profile only exists for licensed accounts (purchase or Game
        // Pass); the entitlement list is recorded for display.
        let owns = ent.contains("game_minecraft") || ent.contains("product_minecraft") || !profile.id.isEmpty
        guard owns else { throw AuthError.notOwned }
        let skin = profile.skins?.first { $0.state == "ACTIVE" } ?? profile.skins?.first

        return MinecraftAccount(
            id: profile.id, username: profile.name, xuid: xuid, skinURL: skin?.url, skinVariant: skin?.variant,
            microsoftRefreshToken: microsoft.refresh_token ?? "",
            minecraftAccessToken: mc.access_token,
            minecraftTokenExpiry: Date().addingTimeInterval(TimeInterval(mc.expires_in)),
            ownsJavaEdition: owns, entitlements: ent)
    }

    private static func xbox(_ url: URL, body: [String: Any]) async throws -> XboxResponse {
        do {
            let data = try await HTTP.postJSON(url, body: body, headers: ["x-xbl-contract-version": "1"])
            return try JSONDecoder().decode(XboxResponse.self, from: data)
        } catch let e as HTTPError where e.status == 401 {
            if e.body.contains("2148916233") { throw AuthError.xbox("This Microsoft account has no Xbox profile. Sign in once at xbox.com to create one.") }
            if e.body.contains("2148916238") { throw AuthError.xbox("Child account: an adult must add it to a Microsoft family to allow Xbox Live sign-in.") }
            if e.body.contains("2148916235") { throw AuthError.xbox("Xbox Live is not available in this account's country/region.") }
            throw AuthError.xbox("Xbox Live authentication failed: \(e.body.prefix(200))")
        }
    }
}

/// Persists accounts in the Keychain and keeps the active one fresh.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [MinecraftAccount] = []
    @Published var activeID: String? { didSet { UserDefaults.standard.set(activeID, forKey: "activeAccount") } }
    @Published var busy = false
    @Published var lastError: String?

    private let authenticator = MicrosoftAuthenticator()
    private let keychainKey = "accounts.v1"

    init() {
        if let data = Keychain.load(account: keychainKey),
           let list = try? JSONDecoder().decode([MinecraftAccount].self, from: data) {
            accounts = list
        }
        activeID = UserDefaults.standard.string(forKey: "activeAccount") ?? accounts.first?.id
    }

    var active: MinecraftAccount? { accounts.first { $0.id == activeID } ?? accounts.first }

    func signIn(clientID: String) async {
        busy = true
        defer { busy = false }
        do {
            let account = try await authenticator.signIn(clientID: clientID)
            store(account)
            activeID = account.id
            lastError = nil
            zlog.info("Signed in as \(account.username)")
        } catch AuthError.cancelled {
            return
        } catch {
            lastError = error.localizedDescription
            zlog.error("Sign-in failed: \(error.localizedDescription)")
        }
    }

    /// Returns a session with a valid Minecraft token, refreshing if needed.
    func validSession(clientID: String) async throws -> MinecraftAccount {
        guard let account = active else { throw AuthError.xbox("Sign in with a Microsoft account that owns Minecraft: Java Edition first.") }
        guard account.needsRefresh else { return account }
        let refreshed = try await MicrosoftAuthenticator.refresh(account, clientID: clientID)
        store(refreshed)
        return refreshed
    }

    func signOut(_ account: MinecraftAccount) {
        accounts.removeAll { $0.id == account.id }
        persist()
        if activeID == account.id { activeID = accounts.first?.id }
        SkinCache.remove(account.id)
    }

    private func store(_ account: MinecraftAccount) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        persist()
    }

    private func persist() {
        do {
            try Keychain.save(try JSONEncoder().encode(accounts), account: keychainKey)
        } catch {
            lastError = "Could not save account to Keychain: \(error.localizedDescription)"
        }
    }
}
