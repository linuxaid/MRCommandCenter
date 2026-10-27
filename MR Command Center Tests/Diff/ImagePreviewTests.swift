import Foundation
import Testing
@testable import MR_Command_Center

struct ImagePreviewTests {
    private func file(_ path: String, oldPath: String? = nil, added: Bool = false, deleted: Bool = false, renamed: Bool = false) -> DiffFile {
        DiffFile(GitLabDiff(oldPath: oldPath ?? path, newPath: path, diff: "Binary files a/\(path) and b/\(path) differ\n",
                            newFile: added, renamedFile: renamed, deletedFile: deleted), index: 0)
    }

    @Test(arguments: [("logo.png", true), ("photo.JPG", true), ("hero.jpeg", true), ("spinner.gif", true),
                      ("icon.webp", true), ("archive.zip", false), ("Font.ttf", false), ("README", false)])
    func recognizesImages(path: String, isImage: Bool) {
        #expect(ImagePreview.isImage(path) == isImage)
    }

    @Test func binaryImagesAreDetectedAsBinary() {
        #expect(file("logo.png").unavailable == .binary)
    }

    @Test func newImageShowsOnlyTheHeadVersion() {
        let sides = ImagePreview.sides(for: file("new.png", added: true), headSHA: "head", baseSHA: "base")
        #expect(sides == [.init(kind: .after, path: "new.png", ref: "head")])
    }

    @Test func deletedImageShowsOnlyTheBaseVersion() {
        let sides = ImagePreview.sides(for: file("gone.png", deleted: true), headSHA: "head", baseSHA: "base")
        #expect(sides == [.init(kind: .before, path: "gone.png", ref: "base")])
    }

    @Test func changedImageShowsBeforeAndAfter() {
        let sides = ImagePreview.sides(for: file("logo.png"), headSHA: "head", baseSHA: "base")
        #expect(sides.map(\.kind) == [.before, .after])
        #expect(sides.map(\.ref) == ["base", "head"])
    }

    @Test func renamedImageUsesEachSidesPath() {
        let sides = ImagePreview.sides(for: file("new/logo.png", oldPath: "old/logo.png", renamed: true), headSHA: "head", baseSHA: "base")
        #expect(sides.map(\.path) == ["old/logo.png", "new/logo.png"])
    }

    @Test func unknownBaseLeavesOutBefore() {
        let sides = ImagePreview.sides(for: file("logo.png"), headSHA: "head", baseSHA: nil)
        #expect(sides.map(\.kind) == [.after])
    }

    @Test func nonImagesHaveNoSides() {
        #expect(ImagePreview.sides(for: file("archive.zip"), headSHA: "head", baseSHA: "base").isEmpty)
    }

    @Test func measuresPixelsAndDescribesSize() throws {
        let data = MockImages.png(width: 64, height: 40)
        let size = try #require(ImagePreview.pixelSize(of: data))
        #expect(size.width == 64 && size.height == 40)
        let text = ImagePreview.sizeDescription(byteCount: data.count, pixelSize: size)
        #expect(text.hasPrefix("64 × 40 px · "))
        #expect(text.hasSuffix(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))
    }

    @Test func notAnImageHasNoPixelSize() {
        #expect(ImagePreview.pixelSize(of: Data("hello".utf8)) == nil)
        #expect(ImagePreview.sizeDescription(byteCount: 2048, pixelSize: nil) == ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file))
    }

    @Test func mockImageIsServedAndCachedPerCommit() async throws {
        let (app, spy, carts, side) = try await cartsImage()

        let data = try await app.diffs.imageData(for: carts, side: side)
        _ = try await app.diffs.imageData(for: carts, side: side)

        #expect(ImagePreview.pixelSize(of: data)?.width == MockImages.size.width)
        #expect(spy.count("rawFile") == 1, "Same commit and path come from the cache")
    }

    @Test func hugeImagesAreNotPreviewedOrKept() async throws {
        let (app, spy, carts, side) = try await cartsImage()
        spy.edit { $0.rawFileOverride = Data(count: DiffService.imagePreviewByteLimit + 1) }

        guard case .failed(let message) = await app.diffs.imagePreview(for: carts, side: side) else {
            Issue.record("Expected a too-large message"); return
        }
        #expect(message.hasPrefix("Too large to preview"))
        _ = try await app.diffs.imageData(for: carts, side: side)
        #expect(spy.count("rawFile") == 2, "Not cached")
    }

    private func cartsImage() async throws -> (AppModel, SpyGitLabClient, TrackedMR, ImagePreview.Side) {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.mergeRequests.refresh(.automatic)
        let carts = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 1873 })
        let diff = try await app.diffs.diff(for: carts)
        let png = try #require(diff.files.first { $0.path.hasSuffix(".png") })
        let sides = ImagePreview.sides(for: png, headSHA: diff.headSHA, baseSHA: diff.refs?.baseSHA)
        return (app, spy, carts, try #require(sides.first))
    }

    @Test func loadsAnImageWithItsSize() async throws {
        let (app, _, carts, side) = try await cartsImage()
        guard case .image(_, let pixels, let text) = await app.diffs.imagePreview(for: carts, side: side) else {
            Issue.record("Expected an image"); return
        }
        #expect(pixels?.width == MockImages.size.width)
        #expect(text.hasPrefix("\(MockImages.size.width) × \(MockImages.size.height) px"))
    }

    @Test func missingFileSaysSoInsteadOfBlamingTheURL() async throws {
        let (app, spy, carts, side) = try await cartsImage()
        spy.edit { $0.rawFileFailure = .notFound }
        guard case .failed(let message) = await app.diffs.imagePreview(for: carts, side: side) else {
            Issue.record("Expected a failure"); return
        }
        #expect(message.contains("isn't in the repository at \(side.ref.prefix(8))"))
        #expect(!message.contains("base URL"))
    }

    @Test func undecodableDataIsReported() async throws {
        let (app, spy, carts, side) = try await cartsImage()
        spy.edit { $0.rawFileOverride = Data("not an image".utf8) }
        guard case .failed(let message) = await app.diffs.imagePreview(for: carts, side: side) else {
            Issue.record("Expected a failure"); return
        }
        #expect(message.contains("isn't an image macOS can read"))
    }

    @Test func failuresAreNotCached() async throws {
        let (app, spy, carts, side) = try await cartsImage()
        spy.edit { $0.rawFileFailure = .offline }
        _ = await app.diffs.imagePreview(for: carts, side: side)
        spy.edit { $0.rawFileFailure = nil }

        guard case .image = await app.diffs.imagePreview(for: carts, side: side) else {
            Issue.record("Trying again should load the image"); return
        }
        #expect(spy.count("rawFile") == 2)
    }

    @Test func cacheKeepsOnlyTheMostRecentImages() async throws {
        let (app, spy, carts, side) = try await cartsImage()
        for index in 0...DiffService.imageCacheLimit {
            let other = ImagePreview.Side(kind: .after, path: side.path, ref: "ref\(index)")
            _ = try await app.diffs.imageData(for: carts, side: other)
        }
        let before = spy.count("rawFile")
        _ = try await app.diffs.imageData(for: carts, side: .init(kind: .after, path: side.path, ref: "ref0"))
        #expect(spy.count("rawFile") == before + 1, "The oldest entry was dropped")
    }
}
