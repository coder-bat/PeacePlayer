//
//  YTAudioPlayerApp.swift
//  YTAudioPlayer
//

import SwiftUI
import CoreData

@main
struct YTAudioPlayerApp: App {
    let persistenceController = PersistenceController.shared

    init() {
        // Migrate UserDefaults data to Core Data on first launch
        DataMigrationService.shared.performMigrationIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.viewContext)
                .ignoresSafeArea(.keyboard)
        }
    }
}
