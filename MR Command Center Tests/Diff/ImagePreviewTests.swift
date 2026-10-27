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
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.mergeRequests.refresh(.automatic)
        let carts = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 1873 })
        let diff = try await app.diffs.diff(for: carts)
        let png = try #require(diff.files.first { $0.path.hasSuffix(".png") })
        let sides = ImagePreview.sides(for: png, headSHA: diff.headSHA, baseSHA: diff.refs?.baseSHA)
        let side = try #require(sides.first)

        let data = try await app.diffs.imageData(for: carts, side: side)
        _ = try await app.diffs.imageData(for: carts, side: side)

        #expect(ImagePreview.pixelSize(of: data)?.width == MockImages.size.width)
        #expect(spy.count("rawFile") == 1, "Same commit and path come from the cache")
    }
}
