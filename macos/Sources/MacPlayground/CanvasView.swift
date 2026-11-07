import AppKit
import PlaygroundModel
import SwiftUI

struct CanvasView: View {
    @Environment(Playground.self) private var playground
    let showOriginal: Bool
    let actualSize: Bool

    var body: some View {
        ZStack {
            Checkerboard()
            if let image = displayed {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: actualSize ? CGFloat(logicalWidth(image)) : nil, height: actualSize ? CGFloat(logicalHeight(image)) : nil)
                        .shadow(radius: 6)
                        .padding(16)
                        .frame(maxWidth: actualSize ? nil : .infinity, maxHeight: actualSize ? nil : .infinity)
                        .accessibilityLabel(showOriginal ? "Original image" : "Result of the current pipeline")
                }
            } else {
                ContentUnavailableView("Open an image", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Drop a file here, use Open…, or pick a sample. Everything is processed on this Mac with Hokusai."))
            }
            if playground.status == .updating { VStack { HStack { Spacer(); Text("Updating…").padding(.horizontal, 10).padding(.vertical, 3).background(.thinMaterial, in: Capsule()) }; Spacer() }.padding(10) }
        }
        .frame(minHeight: 240)
    }

    private var displayed: NSImage? {
        if showOriginal { return playground.sourceData.flatMap { NSImage(data: $0) } }
        return playground.lastGood.flatMap { NSImage(data: $0.data) }
    }

    /// At 100% one image pixel is one point, whatever the display scale, so use the pixel size.
    private func logicalWidth(_ image: NSImage) -> Int { pixelSize(image).width }
    private func logicalHeight(_ image: NSImage) -> Int { pixelSize(image).height }
    private func pixelSize(_ image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first, rep.pixelsWide > 0 { return (rep.pixelsWide, rep.pixelsHigh) }
        return (Int(image.size.width), Int(image.size.height))
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 16
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(.secondary.opacity(0.12)))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityHidden(true)
    }
}
