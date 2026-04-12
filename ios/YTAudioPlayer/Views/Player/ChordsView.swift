//
//  ChordsView.swift
//  YTAudioPlayer
//
//  Displays guitar chords for the current song via Songsterr,
//  embedded natively using WKWebView with dark-theme CSS injection.
//

import SwiftUI
import Combine
import WebKit

struct ChordsView: View {
    @StateObject private var playerState = PlayerState.shared
    @Environment(\.dismiss) private var dismiss

    @State private var chordsURL: URL?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var matchLabel: String?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if isSearching {
                    loadingView
                } else if let error = errorMessage {
                    errorView(message: error)
                } else if let url = chordsURL {
                    ChordsWebView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    emptyView
                }
            }
            .navigationTitle(matchLabel ?? "Guitar Chords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.white)
                }
            }
        }
        .onAppear { fetchChords() }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.white)
            Text("Searching for chords…")
                .font(.subheadline)
                .foregroundColor(Theme.secondaryText)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "guitars")
                .font(.system(size: 48))
                .foregroundColor(Theme.tertiaryText)
            Text("No song playing")
                .foregroundColor(Theme.secondaryText)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "guitars")
                .font(.system(size: 52))
                .foregroundColor(Theme.tertiaryText)
            Text("Chords Not Found")
                .font(.headline)
                .foregroundColor(.white)
            Text(message)
                .font(.subheadline)
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let track = playerState.currentItem?.track {
                Button {
                    let query = "\(track.title) \(track.displayArtist)"
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "https://www.songsterr.com/?pattern=\(query)") {
                        chordsURL = url
                        errorMessage = nil
                    }
                } label: {
                    Label("Open Songsterr Search", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                }
            }
        }
    }

    // MARK: - Data Fetching

    private func fetchChords() {
        guard let track = playerState.currentItem?.track else { return }
        isSearching = true
        errorMessage = nil

        APIService.shared.getChords(title: track.title, artist: track.displayArtist)
            .sink(
                receiveCompletion: { completion in
                    isSearching = false
                    if case .failure(let err) = completion {
                        switch err {
                        case .httpError(let code, _) where code == 404:
                            errorMessage = "No chords available for this song yet."
                        default:
                            errorMessage = "Couldn't reach the chord service.\nCheck your connection and try again."
                        }
                    }
                },
                receiveValue: { result in
                    matchLabel = "\(result.title) — \(result.artist)"
                    chordsURL = URL(string: result.url)
                }
            )
            .store(in: &cancellables)
    }
}

// MARK: - WKWebView wrapper — ad removal, working dropdowns

struct ChordsWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Songsterr already hides its own header on iPhone-width screens via their own CSS.
        // We only suppress ads — deliberately avoiding any fixed/overlay selectors so
        // that JS-driven dropdown menus continue to work correctly.
        let css = """
        iframe,
        [class*="Ad_"], [class*="ad_"], [class*="-ad-"], [class*="_ad_"],
        [class*="AdBanner"], [class*="adBanner"], [class*="advertisement"],
        [class*="Advertisement"], [class*="GoogleAd"], [class*="DFP"],
        [class*="sponsored"], [class*="Sponsored"],
        [id*="google_ads"], [id*="div-gpt-ad"],
        [data-ad], [data-ad-slot], [data-testid*="ad"] {
            display: none !important;
        }
        """

        let styleScript = WKUserScript(
            source: """
            var s = document.createElement('style');
            s.textContent = `\(css)`;
            document.head.appendChild(s);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )

        config.userContentController.addUserScript(styleScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // UIDelegate is required for JS dropdowns / alerts / confirms to function
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url?.absoluteString != url.absoluteString {
            webView.load(URLRequest(url: url))
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        // Allow all in-page navigation
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        // Handle JS alert() — required for some interactive elements
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        // Handle JS confirm() — dropdowns sometimes rely on this
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }

        // Handle JS prompt()
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            completionHandler(defaultText)
        }

        // Allow new windows/tabs opened by JS (e.g. track selection popups)
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

