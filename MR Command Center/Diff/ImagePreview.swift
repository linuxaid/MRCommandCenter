import Foundation
import ImageIO

/// Decides whether a binary file can be previewed as an image, which versions to show,
/// and how to describe its size. Pure, so it's tested without a view.
nonisolated enum ImagePreview {
    /// Formats macOS can decode. The issue named PNG, JPG and GIF; the rest come free.
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "ico"]

    static func isImage(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// One version of the image: before the MR (at the base commit) or after it (at the head).
    struct Side: Equatable, Identifiable {
        enum Kind: Equatable {
            case before, after
        }

        let kind: Kind
        let path: String
        let ref: String

        var id: String { "\(kind)@\(ref):\(path)" }
    }

    /// New images show only "after", deleted ones only "before", and changed or renamed ones both.
    /// A side whose commit isn't known is left out.
    static func sides(for file: DiffFile, headSHA: String, baseSHA: String?) -> [Side] {
        guard isImage(file.path) else { return [] }
        let before = baseSHA.map { Side(kind: .before, path: file.oldPath, ref: $0) }
        let after = headSHA.isEmpty ? nil : Side(kind: .after, path: file.newPath, ref: headSHA)
        return switch file.change {
        case .added: [after].compactMap { $0 }
        case .deleted: [before].compactMap { $0 }
        case .modified, .renamed: [before, after].compactMap { $0 }
        }
    }

    /// Width and height in pixels, or nil if the data isn't an image macOS can read.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// "480 × 300 px · 18 KB", or just the file size when the pixels can't be measured.
    static func sizeDescription(byteCount: Int, pixelSize: (width: Int, height: Int)?) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        guard let pixelSize else { return bytes }
        return "\(pixelSize.width) × \(pixelSize.height) px · \(bytes)"
    }
}
