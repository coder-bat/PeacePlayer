//
//  MemoryTimelineViewModel.swift
//  YTAudioPlayer
//
//  S18 / P1-3: "On this day in your music" Home carousel. Surfaces
//  tracks the user played on this calendar day in prior years.
//  Gives a casual user a reason to open the app daily: "what
//  was I listening to on this day in 2025?"
//
//  Query: CDPlayHistory rows where `playedAt` is in the ±3-day
//  window around today's MM-DD, across all prior years. Group
//  by year, cap at 5 entries per year, total cap 15.
//

import Foundation
import CoreData
import Combine

final class MemoryTimelineViewModel: ObservableObject {
    struct MemoryEntry: Identifiable {
        let id = UUID()
        let year: Int
        let track: CDTrack
        let playedAt: Date
    }

    @Published var entries: [MemoryEntry] = []
    @Published var isLoading: Bool = false
    @Published var hasLoaded: Bool = false

    private let context: NSManagedObjectContext
    private let coreDataContext: () -> NSManagedObjectContext

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        self.coreDataContext = { PersistenceController.shared.container.viewContext }
    }

    /// Fetch entries within ±3 days of today's calendar date for
    /// all prior years. Cheap O(n) scan; cap results at 15.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        load()
    }

    func load() {
        isLoading = true
        let cal = Calendar.current
        let now = Date()
        let nowComps = cal.dateComponents([.year, .month, .day], from: now)
        guard let todayMonth = nowComps.month, let todayDay = nowComps.day else {
            isLoading = false
            hasLoaded = true
            return
        }

        // Compute ±3-day window around today (in current year).
        var startComps = DateComponents()
        startComps.year = nowComps.year
        startComps.month = todayMonth
        startComps.day = todayDay - 3
        var endComps = DateComponents()
        endComps.year = nowComps.year
        endComps.month = todayMonth
        endComps.day = todayDay + 3

        // Pull the full date out 3 days back, then 3 days forward.
        // Adjust if month overflows.
        guard let startDateRaw = cal.date(from: startComps),
              let endDateRaw = cal.date(from: endComps) else {
            isLoading = false
            hasLoaded = true
            return
        }

        let startDate = min(startDateRaw, endDateRaw)
        let endDate = max(startDateRaw, endDateRaw)

        // Fetch all play history (cheaper than complex predicate).
        // S18 / P1-3: the codebase doesn't have many play history
        // rows for typical users (we cap at 2000 via the cleanup
        // timer), so an in-memory filter is fine. If usage grows
        // past 10k rows we'd want a predicate.
        let request: NSFetchRequest<CDPlayHistory> = CDPlayHistory.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "playedAt", ascending: false)]

        let all = (try? context.fetch(request)) ?? []
        let matches = all.filter { row in
            return row.playedAt >= startDate && row.playedAt <= endDate
        }

        // Group by year. Sort within each year by playedAt desc.
        var byYear: [Int: [CDPlayHistory]] = [:]
        for row in matches {
            let year = cal.component(.year, from: row.playedAt)
            byYear[year, default: []].append(row)
        }

        // Cap at 5 per year, then flatten. Skip current year (the
        // ±3-day window hits "today" too which is noise).
        var result: [MemoryEntry] = []
        let currentYear = cal.component(.year, from: now)
        for (year, rows) in byYear.sorted(by: { $0.key > $1.key }) {
            if year == currentYear { continue }
            for row in rows.prefix(5) {
                if let track = row.track {
                    result.append(MemoryEntry(
                        year: year,
                        track: track,
                        playedAt: row.playedAt
                    ))
                }
            }
            if result.count >= 15 { break }
        }

        self.entries = result
        self.isLoading = false
        self.hasLoaded = true
    }
}
