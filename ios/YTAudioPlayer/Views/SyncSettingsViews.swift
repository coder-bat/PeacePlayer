import SwiftUI

struct BackendSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = BackendConfiguration.shared.identity.origin.absoluteString
    @State private var message: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://batuniverse:8181", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Backend server address")
                    Button(testing ? "Testing connection…" : "Test connection") {
                        Task { await testConnection() }
                    }.disabled(testing)
                    if let message { Text(message).font(.callout).accessibilityIdentifier("backendConnectionStatus") }
                } header: {
                    Text("Your server")
                } footer: {
                    Text("Use an HTTP or HTTPS address. The server must be reachable over Wi-Fi or your private network.")
                }
                Section {
                    Button("Save server address") {
                        do {
                            _ = try BackendConfiguration.shared.update(address)
                            dismiss()
                        } catch { message = error.localizedDescription }
                    }.accessibilityIdentifier("saveBackendAddress")
                } footer: {
                    Text("Changing servers signs you out. Downloaded audio and saved libraries stay on this iPhone. Sign in to the new server to restore its backup.")
                }
            }
            .navigationTitle("Backend server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    @MainActor
    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let origin = try BackendConfiguration.normalizedOrigin(address)
            var request = URLRequest(url: origin.appendingPathComponent("health"))
            request.timeoutInterval = 5
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SyncNetworkError.unavailable }
            message = "Connection succeeded. Sign-in is checked separately."
        } catch { message = "Connection failed: \(error.localizedDescription)" }
    }
}

struct BackupStatusSection: View {
    @ObservedObject private var sync = SyncService.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var selected: SavedSyncLibrary?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(sync.statusText).accessibilityIdentifier("backupStatus")
                if let date = sync.lastSuccess {
                    Text("Last backup: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(sync.isBusy ? "Backup in progress…" : "Back up and restore now") { sync.retry() }
                .disabled(sync.isBusy)
            ForEach(sync.savedLibraries) { saved in
                Button {
                    selected = saved
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Import saved local library")
                        Text("\(saved.snapshot.playlists.count) playlists · \(saved.snapshot.favorites.count) liked tracks · \(saved.savedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(sync.isBusy)
            }
        } header: {
            Text("Cloud backup")
        } footer: {
            Text("A saved library from another account or an older installation is kept separately until you choose to import it.")
        }
        .confirmationDialog("Import saved library?", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let selected {
                Button("Import into this account") { sync.importSavedLibrary(id: selected.id); self.selected = nil }
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: {
            Text("Merge this saved library into \(auth.email ?? "the signed-in account") on \(BackendConfiguration.shared.identity.origin.absoluteString)? It will be included in that account’s next backup. The saved copy remains available.")
        }
    }
}
