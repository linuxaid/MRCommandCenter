import AppKit
import Foundation
import SwiftData
import os

/// Fetches MR diffs lazily and caches them per head SHA.
final class DiffService {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let dependencies: AppDependencies

    init(container: ModelContainer, dependencies: AppDependencies) {
        self.container = container
        self.dependencies = dependencies
    }

    /// Returns the cached diff for the MR's current head SHA, fetching it if needed.
    func diff(for mr: TrackedMR, forceRefresh: Bool = false) async throws -> MRDiff {
        let key = mr.key
        let headSHA = mr.headSHA
        if !forceRefresh, let snapshot = cachedSnapshot(mrKey: key, headSHA: headSHA) {
            return try await Self.parse(snapshot.decodedDiffs(), headSHA: headSHA, changesCount: snapshot.changesCount,
                                        fetchedAt: snapshot.fetchedAt, refs: snapshot.refs ?? mr.diffRefs)
        }

        let settings = AccountSettings.current(in: context)
        let client = try dependencies.gitLabClient(settings: settings)
        let diffs = try await client.diffs(projectID: mr.projectID, iid: mr.iid)
        let now = Date.now
        let refs = mr.diffRefs
        store(diffs, mrKey: key, headSHA: headSHA, changesCount: mr.changesCount, refs: refs, fetchedAt: now)
        return await Self.parse(diffs, headSHA: headSHA, changesCount: mr.changesCount, fetchedAt: now, refs: refs)
    }

    /// Image bytes for previews, cached in memory per commit and path (a commit's file never
    /// changes). Only successes are cached, and only the most recent few, oldest dropped first.
    private var imageCache: [String: Data] = [:]
    private var imageCacheOrder: [String] = []
    static let imageCacheLimit = 24
    /// Bigger images aren't previewed (or kept): they'd sit in memory and decode on the main actor.
    static let imagePreviewByteLimit = 15 * 1024 * 1024

    func imageData(for mr: TrackedMR, side: ImagePreview.Side) async throws -> Data {
        let key = "\(mr.projectID):\(side.ref):\(side.path)"
        if let cached = imageCache[key] { return cached }
        let client = try dependencies.gitLabClient(settings: AccountSettings.current(in: context))
        let data = try await client.rawFile(projectID: mr.projectID, path: side.path, ref: side.ref)
        guard data.count <= Self.imagePreviewByteLimit else { return data }
        if imageCache[key] == nil { imageCacheOrder.append(key) }
        imageCache[key] = data
        while imageCacheOrder.count > Self.imageCacheLimit {
            imageCache[imageCacheOrder.removeFirst()] = nil
        }
        return data
    }

    /// Fetches and decodes one side of an image preview, turning every failure into a readable message.
    func imagePreview(for mr: TrackedMR, side: ImagePreview.Side) async -> ImagePreview.Loaded {
        do {
            let data = try await imageData(for: mr, side: side)
            guard data.count <= Self.imagePreviewByteLimit else {
                return .failed("Too large to preview here (\(ImagePreview.sizeDescription(byteCount: data.count, pixelSize: nil))).")
            }
            guard let image = NSImage(data: data) else {
                return .failed("This file isn't an image macOS can read (\(ImagePreview.sizeDescription(byteCount: data.count, pixelSize: nil))).")
            }
            let pixels = ImagePreview.pixelSize(of: data)
            return .image(image, pixels: pixels, sizeText: ImagePreview.sizeDescription(byteCount: data.count, pixelSize: pixels))
        } catch is CancellationError {
            return .cancelled
        } catch APIError.notFound {
            return .failed("This version of the image isn't in the repository at \(side.ref.prefix(8)).")
        } catch {
            return .failed("Couldn't load the image: \(error.localizedDescription)")
        }
    }

    func cachedSnapshot(mrKey: String, headSHA: String) -> DiffSnapshot? {
        let id = DiffSnapshot.makeID(mrKey: mrKey, headSHA: headSHA)
        var descriptor = FetchDescriptor<DiffSnapshot>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func store(_ diffs: [GitLabDiff], mrKey: String, headSHA: String, changesCount: String?, refs: DiffRefs?, fetchedAt: Date) {
        do {
            // Older commits' diffs aren't needed for display; AI runs and eval cases keep their own copies.
            let stale = try context.fetch(FetchDescriptor<DiffSnapshot>(predicate: #Predicate { $0.mrKey == mrKey }))
            stale.forEach(context.delete)
            context.insert(try DiffSnapshot(mrKey: mrKey, headSHA: headSHA, diffs: diffs, changesCount: changesCount, refs: refs, fetchedAt: fetchedAt))
            try context.save()
        } catch {
            Log.persistence.error("Caching diff failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @concurrent
    private nonisolated static func parse(_ diffs: [GitLabDiff], headSHA: String, changesCount: String?, fetchedAt: Date, refs: DiffRefs?) async -> MRDiff {
        MRDiff(headSHA: headSHA, diffs: diffs, changesCount: changesCount, fetchedAt: fetchedAt, refs: refs)
    }
}
