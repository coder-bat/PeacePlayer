//
//  AuthService.swift
//  PeacePlayer
//
//  Apple Sign-In + JWT session management.
//
//  2026-06-28: Apple login is now mandatory for the next version.
//  There is no guest path — first launch shows the LandingView
//  with only a "Sign in with Apple" button. On successful sign-in
//  the session JWT is stored in Keychain and posted as a Bearer
//  token on every subsequent backend request.
//

import Foundation
import UIKit
import AuthenticationServices
import Combine

@MainActor
final class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()

    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var userId: String?
    @Published private(set) var email: String?
    @Published private(set) var isSigningIn: Bool = false
    @Published private(set) var lastError: String?

    private var configurationObserver: NSObjectProtocol?
    private(set) var sessionGeneration: UInt64 = 0
    private let keychain = KeychainHelper.shared
    private let sessionTokenKey = "peaceplayer.session_token"
    private let userIdKey = "peaceplayer.user_id"
    private let emailKey = "peaceplayer.email"
    private let expiresAtKey = "peaceplayer.expires_at"

    /// Stored delegate so it isn't deallocated mid-flow.
    private var currentDelegate: AppleIDDelegate?

    private override init() {
        super.init()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: BackendConfiguration.didChange, object: BackendConfiguration.shared, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateSession()
                StreamURLCache.shared.clear()
            }
        }

    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard keychain.read(APIService.authOriginKeychainKey) == BackendConfiguration.shared.identity.origin.absoluteString else {
            invalidateSession()
            return
        }
        guard
            let _ = keychain.read(sessionTokenKey),
            let userId = keychain.read(userIdKey)
        else {
            isAuthenticated = false
            return
        }

        if let expiresStr = keychain.read(expiresAtKey),
           let expires = TimeInterval(expiresStr),
           expires < Date().timeIntervalSince1970 {
            clearSession()
            isAuthenticated = false
            return
        }

        self.userId = userId
        self.email = keychain.read(emailKey)
        self.isAuthenticated = true

        // 2026-06-28 (Phase 3): on a returning user, pull the
        // latest cloud state and merge it into local Core Data.
        SyncService.shared.handleSessionRestored()
    }

    func signIn() async {
        let startingBackend = BackendConfiguration.shared.identity
        let startingGeneration = sessionGeneration
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }

        let result: AppleIDResult
        do {
            result = try await runAppleIDFlow()
        } catch let error as AppleIDError {
            if case .userCancelled = error { return }
            lastError = error.message
            return
        } catch {
            lastError = "Apple sign-in failed: \(error.localizedDescription)"
            return
        }

        do {
            guard BackendConfiguration.shared.isCurrent(startingBackend), sessionGeneration == startingGeneration else { return }
            try await postToBackend(result: result)
        } catch {
            lastError = "Server sign-in failed: \(error.localizedDescription)"
        }
    }

    func signOut() async {
        var request = URLRequest(url: BackendConfiguration.shared.identity.url(path: "/auth/signout"))
        request.httpMethod = "POST"
        APIService.addAuthHeader(to: &request)
        invalidateSession()
        _ = try? await URLSession.shared.data(for: request)
    }

    func invalidateSession() {
        sessionGeneration &+= 1
        SyncService.shared.handleSignOut()
        clearSession()
        isAuthenticated = false
    }

    private func clearSession() {
        keychain.delete(APIService.authOriginKeychainKey)
        keychain.delete(sessionTokenKey)
        keychain.delete(userIdKey)
        keychain.delete(emailKey)
        keychain.delete(expiresAtKey)
        userId = nil
        email = nil
    }

    // MARK: - Apple ID flow

    struct AppleIDResult {
        let identityToken: String
        let authorizationCode: String?
        let user: String?
        let email: String?
    }

    private func runAppleIDFlow() async throws -> AppleIDResult {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let delegate = AppleIDDelegate()
        self.currentDelegate = delegate
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = delegate
        controller.presentationContextProvider = delegate
        controller.performRequests()

        return try await delegate.future.value
    }

    // MARK: - Backend

    private struct AppleSignInRequest: Encodable {
        let identityToken: String
        let authorizationCode: String?
        let user: String?
        let email: String?
    }

    private struct AppleSignInResponse: Decodable {
        let userId: String
        let sessionToken: String
        let expiresAt: Int
        let email: String?
        let isNewUser: Bool
        let serverTime: Int
    }

    private func postToBackend(result: AppleIDResult) async throws {
        let identity = BackendConfiguration.shared.identity
        let generation = sessionGeneration
        var request = URLRequest(url: identity.url(path: "/auth/apple"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = AppleSignInRequest(
            identityToken: result.identityToken,
            authorizationCode: result.authorizationCode,
            user: result.user,
            email: result.email
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown error"
            throw AppleIDError.backend(detail)
        }

        guard BackendConfiguration.shared.isCurrent(identity), sessionGeneration == generation else {
            throw CancellationError()
        }
        let decoded = try JSONDecoder().decode(AppleSignInResponse.self, from: data)
        keychain.write(APIService.authOriginKeychainKey, identity.origin.absoluteString)

        keychain.write(sessionTokenKey, decoded.sessionToken)
        keychain.write(userIdKey, decoded.userId)
        if let email = decoded.email {
            keychain.write(emailKey, email)
        } else {
            keychain.delete(emailKey)
        }
        keychain.write(expiresAtKey, String(decoded.expiresAt))
        guard keychain.read(sessionTokenKey) == decoded.sessionToken,
              keychain.read(userIdKey) == decoded.userId,
              keychain.read(APIService.authOriginKeychainKey) == identity.origin.absoluteString else {
            invalidateSession()
            throw AppleIDError.backend("Could not securely save sign-in. Please try again.")
        }

        self.userId = decoded.userId
        self.email = decoded.email
        self.isAuthenticated = true

        // 2026-06-28 (Phase 3): kick off the cloud backup. For
        // a new user we also pull the existing state (likely
        // empty on first install); for returning users we just
        // re-upload to confirm.
        SyncService.shared.handleSignIn(isNewUser: decoded.isNewUser)
    }

    private func postSignOut() async throws -> Data {
        // S17 (CV-3): use the central APIService.addAuthHeader
        // helper so the Bearer-token construction is in one
        // place. The keychain read happens inside the helper.
        var request = URLRequest(url: BackendConfiguration.shared.identity.url(path: "/auth/signout"))
        request.httpMethod = "POST"
        APIService.addAuthHeader(to: &request)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    // MARK: - Errors

    enum AppleIDError: Error {
        case userCancelled
        case noCredential
        case backend(String)

        var message: String {
            switch self {
            case .userCancelled: return ""
            case .noCredential: return "Apple didn't return a credential."
            case .backend(let detail): return "Sign-in failed: \(detail)"
            }
        }
    }
}

// MARK: - Apple ID delegate

private final class AppleIDDelegate: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    let future: Future<AuthService.AppleIDResult, Error>
    private let promise: Future<AuthService.AppleIDResult, Error>.Promise

    override init() {
        var p: Future<AuthService.AppleIDResult, Error>.Promise!
        self.future = Future { p = $0 }
        self.promise = p
        super.init()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? UIWindow()
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else {
            promise(.failure(AuthService.AppleIDError.noCredential))
            return
        }
        guard
            let tokenData = cred.identityToken,
            let token = String(data: tokenData, encoding: .utf8)
        else {
            promise(.failure(AuthService.AppleIDError.noCredential))
            return
        }
        let code = cred.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        promise(.success(.init(
            identityToken: token,
            authorizationCode: code,
            user: cred.user,
            email: cred.email
        )))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            promise(.failure(AuthService.AppleIDError.userCancelled))
        } else {
            promise(.failure(AuthService.AppleIDError.backend(error.localizedDescription)))
        }
    }
}
