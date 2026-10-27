import SwiftUI

/// A binary image file shown as the image itself, with its pixel size and file size.
/// Changed images show before and after side by side (stacked when narrow).
struct ImagePreviewView: View {
    let file: DiffFile
    let mr: TrackedMR
    let refs: DiffRefs?
    let openInBrowser: () -> Void
    /// Too narrow for two images side by side: stack them. Measured, never a content minimum
    /// (see the AppKit layout loop gotcha in PLAN.md).
    @State private var isNarrow = false

    var body: some View {
        let sides = ImagePreview.sides(for: file, headSHA: refs?.headSHA ?? mr.headSHA, baseSHA: refs?.baseSHA ?? mr.baseSHA)
        ScrollView {
            Group {
                if isNarrow || sides.count < 2 {
                    VStack(alignment: .leading, spacing: 16) { panels(sides) }
                } else {
                    HStack(alignment: .top, spacing: 16) { panels(sides) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 560 } action: { isNarrow = $0 }
        .overlay {
            if sides.isEmpty {
                ContentUnavailableView {
                    Label("Can't Preview This Image", systemImage: "photo")
                } description: {
                    Text("GitLab didn't send the commit references needed to fetch it.")
                } actions: {
                    Button("Open in Browser", action: openInBrowser)
                }
            }
        }
    }

    private func panels(_ sides: [ImagePreview.Side]) -> some View {
        ForEach(sides) { side in
            ImageSidePanel(mr: mr, side: side, title: title(for: side, count: sides.count))
        }
    }

    private func title(for side: ImagePreview.Side, count: Int) -> String {
        switch (side.kind, file.change) {
        case (.after, .added): "New image"
        case (.before, .deleted): "Deleted image"
        case (.before, _): "Before"
        case (.after, _): "After"
        }
    }
}

private struct ImageSidePanel: View {
    let mr: TrackedMR
    let side: ImagePreview.Side
    let title: String
    @Environment(AppModel.self) private var appModel
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(NSImage, String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if case .loaded(_, let size) = state {
                    Text(size)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            content
                .frame(maxWidth: 520, maxHeight: 420)
                .background(Checkerboard())
                .clipShape(.rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .task(id: side.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        case .loaded(let image, _):
            // Shrinks to fit, but never enlarges small images (icons stay crisp at their real size).
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .accessibilityLabel("\(title), \(side.path)")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private func load() async {
        do {
            let data = try await appModel.diffs.imageData(for: mr, side: side)
            guard let image = NSImage(data: data) else {
                state = .failed("Couldn't read this image (\(ImagePreview.sizeDescription(byteCount: data.count, pixelSize: nil))).")
                return
            }
            state = .loaded(image, ImagePreview.sizeDescription(byteCount: data.count, pixelSize: ImagePreview.pixelSize(of: data)))
        } catch is CancellationError {
            return
        } catch {
            state = .failed("Couldn't load the image: \(error.localizedDescription)")
        }
    }
}

/// Light gray checks behind images, so transparent areas are visible.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(Color(white: 0.92)))
                }
            }
        }
    }
}
