//
//  ErrorHandler.swift
//  YTAudioPlayer
//
//  Centralized error handling with user-friendly messages and retry support
//

import Foundation
import SwiftUI
import Combine

/// Types of errors the app can encounter
enum AppError: Error, Equatable {
    case network(String)
    case server(Int, String)
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case notFound
    case parsing(String)
    case downloadFailed(String)
    case playbackFailed(String)
    case authRequired
    case unknown(String)
    // S18 / P1-10: non-error informational toast. Used for "in
    // progress" feedback (e.g. "Reconnecting…") where we want a
    // toast lifecycle without the negative framing of an error.
    case info(String)

    var title: String {
        switch self {
        case .network: return "Connection Error"
        case .server: return "Server Error"
        case .rateLimited: return "Slow Down"
        case .offline: return "You're Offline"
        case .notFound: return "Not Found"
        case .parsing: return "Data Error"
        case .downloadFailed: return "Download Failed"
        case .playbackFailed: return "Playback Error"
        case .authRequired: return "Sign In Required"
        case .unknown: return "Something Went Wrong"
        case .info: return ""
        }
    }

    var message: String {
        switch self {
        case .network(let msg):
            return msg.isEmpty ? "Please check your internet connection and try again." : msg
        case .server(let code, let msg):
            if code == 500 {
                return "The server encountered an error. Please try again later."
            } else if code == 404 {
                return "The requested content could not be found."
            }
            return msg.isEmpty ? "A server error occurred. Please try again." : msg
        case .rateLimited(let retryAfter):
            // S15: previously 429 was collapsed to a generic
            // "check your internet" message. Now the user sees a
            // real explanation and an explicit wait time when the
            // server sent a Retry-After header.
            if let seconds = retryAfter {
                return "You're going a bit fast — try again in \(Int(seconds))s."
            }
            return "You're going a bit fast — wait a moment and try again."
        case .offline:
            // S17-H: distinguish "your device is offline" (the
            // .network case above) from "your backend is unreachable"
            // (this case). The latter usually means the Mac
            // running the backend is asleep, the Tailscale IP
            // changed, or the backend was stopped.
            return "Can't reach the PeacePlayer backend. Check that your Mac is awake and the backend host in Settings is correct."
        case .notFound:
            return "The requested item could not be found."
        case .parsing:
            return "We couldn't process the data. Please try again."
        case .downloadFailed(let msg):
            return msg.isEmpty ? "The download failed. Please try again." : msg
        case .playbackFailed(let msg):
            return msg.isEmpty ? "Unable to play this track. Please try another." : msg
        case .authRequired:
            return "Please sign in to access this feature."
        case .unknown(let msg):
            return msg.isEmpty ? "An unexpected error occurred. Please try again." : msg
        case .info(let msg):
            return msg
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network, .server, .rateLimited, .offline, .downloadFailed, .unknown:
            return true
        case .notFound, .parsing, .playbackFailed, .authRequired:
            return false
        case .info:
            return false
        }
    }
    
    var icon: String {
        switch self {
        case .network, .offline:
            return "wifi.slash"
        case .server:
            return "server.rack"
        case .rateLimited:
            return "hourglass"
        case .notFound:
            return "magnifyingglass"
        case .parsing:
            return "doc.text.magnifyingglass"
        case .downloadFailed:
            return "arrow.down.circle"
        case .playbackFailed:
            return "play.slash"
        case .authRequired:
            return "lock"
        case .unknown:
            return "exclamationmark.triangle"
        case .info:
            return "antenna.radiowaves.left.and.right"
        }
    }

    var color: Color {
        switch self {
        case .network, .offline, .server, .rateLimited, .unknown:
            return .orange
        case .notFound, .parsing:
            return Theme.tertiaryText
        case .downloadFailed, .playbackFailed:
            return .red
        case .authRequired:
            return .blue
        case .info:
            return Theme.cyberCyan
        }
    }
}

/// Converts APIError to AppError
extension APIError {
    func toAppError() -> AppError {
        switch self {
        case .invalidURL:
            return .network("Invalid URL")
        case .invalidResponse:
            return .parsing("Invalid response from server")
        case .rateLimited(let retryAfter):
            // S15: 429 used to be lumped into .httpError -> .network
            // -> "check your internet", which is the worst possible
            // mapping. Surface it directly so the user sees a
            // real "slow down" message.
            return .rateLimited(retryAfter: retryAfter)
        case .httpError(let code, let message):
            if code == 404 {
                return .notFound
            } else if code >= 500 {
                return .server(code, message)
            } else {
                // Other 4xx (400, 401, 403, etc.) — preserve the
                // status code in the message instead of claiming
                // it's a network problem.
                return .server(code, message)
            }
        case .decodingError:
            return .parsing("Failed to decode response")
        case .networkError(let underlying):
            // S17-H (failure modes 5): distinguish "your internet is
            // down" from "the backend is unreachable" from "we just
            // lost connectivity briefly". The old mapping collapsed
            // all of these to .network("") → "check your internet",
            // which is the wrong message when the Mac is asleep, the
            // Tailscale IP changed, or the backend was just stopped.
            //
            // URLError codes we care about:
            //   .notConnectedToInternet → user's Wi-Fi/data is off
            //   .cannotFindHost          → DNS failed (also user side)
            //   .timedOut                → could be either; treat as
            //                                backend-unreachable after
            //                                our retry exhausted
            //   .cannotConnectToHost     → backend is down / wrong IP
            //   .networkConnectionLost   → transient (already retried)
            //   other                    → unknown
            if let urlError = underlying as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .cannotFindHost, .dataNotAllowed:
                    return .network("Your device appears to be offline. Check your Wi-Fi or cellular connection.")
                case .cannotConnectToHost:
                    return .offline
                case .timedOut:
                    return .offline
                case .networkConnectionLost:
                    return .network("Connection dropped. Try again.")
                default:
                    return .network("")
                }
            }
            return .network("")
        }
    }
}

/// Central error handler with presentation state
class ErrorHandler: ObservableObject {
    static let shared = ErrorHandler()
    
    @Published var currentError: AppError?
    @Published var showError = false
    
    private var retryAction: (() -> Void)?
    
    private init() {}
    
    /// Show an error with optional retry action
    func show(_ error: AppError, retry: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            self.currentError = error
            self.retryAction = retry
            self.showError = true
            HapticManager.error()
        }
    }

    /// S18 / P1-10: show a non-error informational toast. Same
    /// surface as `show(_:retry:)` but no error haptic and no
    /// retry button — the user is being told something is in
    /// progress, not that something went wrong.
    func showInfo(_ message: String) {
        DispatchQueue.main.async {
            self.currentError = .info(message)
            self.retryAction = nil
            self.showError = true
            // Light haptic only — no error pattern.
            HapticManager.light()
        }
    }
    
    /// Handle API error with automatic conversion
    func handleAPIError(_ error: APIError, retry: (() -> Void)? = nil) {
        show(error.toAppError(), retry: retry)
    }
    
    /// Execute retry action if available
    func retry() {
        retryAction?()
        clear()
    }
    
    /// Clear current error
    func clear() {
        currentError = nil
        retryAction = nil
        showError = false
    }
}

// MARK: - SwiftUI Views

/// Reusable error banner view
struct ErrorBanner: View {
    let error: AppError
    let onDismiss: () -> Void
    let onRetry: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: error.icon)
                    .font(.title2)
                    .foregroundColor(error.color)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.title)
                        .font(.headline.bold())
                        .foregroundColor(.primary)
                    
                    Text(error.message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
            }
            
            if error.isRetryable, onRetry != nil {
                Button(action: { onRetry?() }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(error.color)
                    .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        .padding(.horizontal)
    }
}

/// Full-screen error view
struct ErrorStateView: View {
    let error: AppError
    let onRetry: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: error.icon)
                .font(.system(size: 70))
                .foregroundColor(error.color)
            
            Text(error.title)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(error.message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            if error.isRetryable, let onRetry = onRetry {
                Button(action: onRetry) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(error.color)
                    .cornerRadius(12)
                }
                .padding(.top, 16)
            }
            
            Spacer()
        }
    }
}

/// View modifier for error handling
struct ErrorAlertModifier: ViewModifier {
    @StateObject private var errorHandler = ErrorHandler.shared
    
    func body(content: Content) -> some View {
        content
            .alert(
                errorHandler.currentError?.title ?? "Error",
                isPresented: $errorHandler.showError,
                presenting: errorHandler.currentError
            ) { error in
                if error.isRetryable {
                    Button("Try Again") {
                        errorHandler.retry()
                    }
                }
                Button("OK", role: .cancel) {
                    errorHandler.clear()
                }
            } message: { error in
                Text(error.message)
            }
    }
}

extension View {
    func errorAlert() -> some View {
        modifier(ErrorAlertModifier())
    }
}

// MARK: - Combine Extension

extension Publisher where Failure == APIError {
    /// Handle errors with ErrorHandler and optionally retry
    func handleErrors(
        with handler: ErrorHandler = .shared,
        retry: (() -> Void)? = nil
    ) -> AnyPublisher<Output, Never> {
        self
            .catch { error -> Empty<Output, Never> in
                handler.handleAPIError(error, retry: retry)
                return Empty()
            }
            .eraseToAnyPublisher()
    }
}
