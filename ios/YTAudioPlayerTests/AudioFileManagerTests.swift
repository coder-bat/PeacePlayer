//
//  AudioFileManagerTests.swift
//  YTAudioPlayerTests
//
//  C-5 fix verification: AudioFileManager.isPlayable reconciles stale
//  CDDownloadedTrack rows. The function consults Core Data first, falls
//  back to filesystem, and removes stale rows (file missing) so the
//  PlayerState.play(track:) path never silently streams a track that's
//  listed as Downloaded.
//
//  Reference: project-playback-gap-analysis-2026-06-16.md, C-5
//

import XCTest
import CoreData
@testable import PeacePlayer

final class AudioFileManagerTests: XCTestCase {

    var sut: AudioFileManager!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        sut = AudioFileManager.shared
        // Use an in-memory Core Data stack so tests don't pollute the
        // real store and don't depend on the app's PersistenceController.
        context = makeInMemoryContext()
    }

    override func tearDown() {
        sut = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeInMemoryContext() -> NSManagedObjectContext {
        // Build a minimal managed object model with the entities we need
        // (CDDownloadedTrack + CDTrack) using the existing class
        // definitions. NSManagedObject subclasses auto-generate the
        // entity description at runtime; we just need a model container.
        let model = NSManagedObjectModel()

        let trackEntity = NSEntityDescription()
        trackEntity.name = "CDTrack"
        trackEntity.managedObjectClassName = NSStringFromClass(CDTrack.self)

        let videoId = NSAttributeDescription()
        videoId.name = "videoId"
        videoId.attributeType = .stringAttributeType
        videoId.isOptional = false
        trackEntity.properties.append(videoId)

        let downloadedEntity = NSEntityDescription()
        downloadedEntity.name = "CDDownloadedTrack"
        downloadedEntity.managedObjectClassName = NSStringFromClass(CDDownloadedTrack.self)

        let trackRel = NSRelationshipDescription()
        trackRel.name = "track"
        trackRel.destinationEntity = trackEntity
        trackRel.maxCount = 1
        trackRel.minCount = 0
        trackRel.isOptional = true
        trackRel.deleteRule = .nullifyDeleteRule

        let downloadedProps = NSMutableArray()
        downloadedProps.add(trackRel)
        downloadedEntity.properties = downloadedProps as? [NSPropertyDescription] ?? []
        trackEntity.properties.append(trackRel)

        model.entities = [trackEntity, downloadedEntity]

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try? coordinator.addPersistentStore(
            ofType: NSInMemoryStoreType,
            configurationName: nil,
            at: nil,
            options: nil
        )
        let ctx = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        ctx.persistentStoreCoordinator = coordinator
        return ctx
    }

    @discardableResult
    private func seedCoreDataRow(videoId: String) -> CDDownloadedTrack {
        let track = CDTrack(context: context)
        track.videoId = videoId
        let row = CDDownloadedTrack(context: context)
        row.track = track
        try? context.save()
        return row
    }

    private func writeFile(videoId: String) {
        let url = sut.localFileURL(for: videoId)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data("test".utf8))
    }

    private func deleteFile(videoId: String) {
        let url = sut.localFileURL(for: videoId)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - C-5 reconciliation

    /// The bug: a row in CDDownloadedTrack but no file on disk should
    /// be removed (stale), and isPlayable should return false.
    func testIsPlayable_staleRowMissingFile_returnsFalse_andDeletesRow() {
        let videoId = "stale-test-\(UUID().uuidString.prefix(8))"
        seedCoreDataRow(videoId: String(videoId))
        // Note: NOT writing the file — this is the stale state

        let result = sut.isPlayable(videoId: String(videoId), context: context)

        XCTAssertFalse(result, "isPlayable should return false when row exists but file is missing")
        let count = (try? context.count(for: CDDownloadedTrack.fetchRequest())) ?? 0
        XCTAssertEqual(count, 0, "Stale row should have been removed by isPlayable")
    }

    /// The happy path: row exists, file exists, isPlayable returns true.
    func testIsPlayable_rowAndFileExist_returnsTrue_keepsRow() {
        let videoId = "good-test-\(UUID().uuidString.prefix(8))"
        seedCoreDataRow(videoId: String(videoId))
        writeFile(videoId: String(videoId))
        defer { deleteFile(videoId: String(videoId)) }

        let result = sut.isPlayable(videoId: String(videoId), context: context)

        XCTAssertTrue(result)
        let count = (try? context.count(for: CDDownloadedTrack.fetchRequest())) ?? 0
        XCTAssertEqual(count, 1, "Valid row should not be removed")
    }

    /// No row, no file: not downloadable. (Bootstrap() handles the orphan
    /// recovery in production; isPlayable just answers the question.)
    func testIsPlayable_noRowNoFile_returnsFalse() {
        let videoId = "neither-test-\(UUID().uuidString.prefix(8))"

        let result = sut.isPlayable(videoId: String(videoId), context: context)

        XCTAssertFalse(result)
    }

    /// File exists but no row: isPlayable returns true (file is on disk
    /// and playable). The orphan will be flagged by
    /// BackgroundDownloadService.bootstrap().
    func testIsPlayable_fileExistsNoRow_returnsTrue_doesNotCreateRow() {
        let videoId = "orphan-test-\(UUID().uuidString.prefix(8))"
        writeFile(videoId: String(videoId))
        defer { deleteFile(videoId: String(videoId)) }

        let result = sut.isPlayable(videoId: String(videoId), context: context)

        XCTAssertTrue(result, "isPlayable should return true when the file exists even without a row")
        let count = (try? context.count(for: CDDownloadedTrack.fetchRequest())) ?? 0
        XCTAssertEqual(count, 0, "isPlayable should not create Core Data rows — bootstrap does that")
    }
}
