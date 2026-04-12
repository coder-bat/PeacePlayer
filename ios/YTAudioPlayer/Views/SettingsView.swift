import SwiftUI

struct SettingsView: View {
    @State private var showClearCacheConfirmation = false
    @State private var cacheSize: String = "Calculating..."

    var body: some View {
        // NOTE: No NavigationView here - ContentView already manages navigation
        ZStack {
            Theme.cyberBackground.ignoresSafeArea()

            List {
                // MARK: - Music Sources Section
                Section {
                    // YouTube (always active)
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.2))
                                .frame(width: 44, height: 44)

                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.red)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("YouTube")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)

                            Text("Active")
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    Text("Music Sources")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
                }

                // MARK: - Storage Section
                Section {
                    HStack {
                        Label {
                            Text("Cache Size")
                        } icon: {
                            Image(systemName: "externaldrive.fill")
                                .foregroundColor(Theme.cyberCyan)
                        }
                        .foregroundColor(.white)

                        Spacer()

                        Text(cacheSize)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .listRowBackground(Theme.cyberSurface)

                    Button {
                        showClearCacheConfirmation = true
                    } label: {
                        Label {
                            Text("Clear Cache")
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    Text("Storage")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
                }

                // MARK: - About Section
                Section {
                    HStack {
                        Label {
                            Text("Version")
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(Theme.cyberCyan)
                        }
                        .foregroundColor(.white)

                        Spacer()

                        Text("1.0.0")
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    Text("About")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
                }
            }
            .listStyle(.insetGrouped)
            .background(Theme.cyberBackground)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            "Clear Cache?",
            isPresented: $showClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                clearCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all cached artwork and temporary files. Your downloaded music will not be affected.")
        }
        .onAppear {
            calculateCacheSize()
        }
        .preferredColorScheme(.dark)
    }

    private func calculateCacheSize() {
        let size = ImageCache.shared.cacheSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        cacheSize = formatter.string(fromByteCount: Int64(size))
    }

    private func clearCache() {
        ImageCache.shared.clearCache()
        calculateCacheSize()
    }
}

// MARK: - Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
