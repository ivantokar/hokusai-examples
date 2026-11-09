import AppKit
import HokusaiRecipes
import PlaygroundModel
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Playground.self) private var playground
    @State private var showInspector = true
    @State private var showCode = true
    @State private var showOriginal = false
    @State private var actualSize = false
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        @Bindable var playground = playground
        NavigationSplitView {
            PipelineView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                CanvasView(showOriginal: showOriginal, actualSize: actualSize)
                StatusBar(message: message)
                if showCode { CodePanel().frame(height: 190) }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView().inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Open…", systemImage: "photo") { importing = true }.help("Open an image")
                Menu("Samples", systemImage: "photo.stack") {
                    ForEach(Samples.all) { sample in Button(sample.title) { openSample(sample) } }
                }
                Menu("Recipes", systemImage: "wand.and.stars") {
                    ForEach(Presets.all, id: \.id) { preset in
                        Button(preset.title) { apply(preset) }
                    }
                }
            }
            ToolbarItemGroup {
                Button("Undo", systemImage: "arrow.uturn.backward") { playground.undo() }.disabled(!playground.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { playground.redo() }.disabled(!playground.canRedo)
                Picker("Compare", selection: $showOriginal) { Text("Result").tag(false); Text("Original").tag(true) }
                    .pickerStyle(.segmented).help("Compare with the original")
                Picker("Zoom", selection: $actualSize) { Text("Fit").tag(false); Text("100%").tag(true) }.pickerStyle(.segmented)
                Toggle("Full size", isOn: $playground.showFullSize).toggleStyle(.button)
                    .help("Evaluate the result at its real size instead of the reduced preview")
                Toggle("Code", systemImage: "chevron.left.forwardslash.chevron.right", isOn: $showCode).help("Show the Swift code")
                Button("Export…", systemImage: "square.and.arrow.up") { Task { await export() } }
                    .disabled(playground.sourceData == nil)
                Toggle("Inspector", systemImage: "sidebar.trailing", isOn: $showInspector)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { Task { await open(url: url) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await open(url: url) }
            return true
        }
        .task {
            playground.pictures = { Samples.data($0) }
            if playground.sourceData == nil, let first = Samples.all.first, let data = Samples.data(first.file) { try? await playground.open(data: data, name: first.file) }
        }
    }

    private func open(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await playground.open(data: try Data(contentsOf: url), name: url.lastPathComponent); message = nil }
        catch { message = "Could not open \(url.lastPathComponent): \(Playground.message(for: error))" }
    }

    private func openSample(_ sample: Samples.Sample) {
        guard let data = Samples.data(sample.file) else { message = "The sample is missing from the app bundle."; return }
        Task { try? await playground.open(data: data, name: sample.file); message = nil }
    }

    private func apply(_ preset: Preset) {
        Task {
            if let data = Samples.data(preset.sample), playground.sourceName != preset.sample, !(playground.sourceName.map { Samples.all.map(\.file).contains($0) == false } ?? false) {
                try? await playground.open(data: data, name: preset.sample)
            }
            playground.apply(preset: preset)
        }
    }

    private func export() async {
        do {
            let result = try await playground.exportData()
            let panel = NSSavePanel()
            let base = (playground.sourceName ?? "image").split(separator: ".").dropLast().joined(separator: ".")
            panel.nameFieldStringValue = "\(base)-hokusai.\(result.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try result.data.write(to: url)
            message = "Exported \(result.image.width) × \(result.image.height), \(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file))"
        } catch { message = Playground.message(for: error) }
    }
}

struct StatusBar: View {
    @Environment(Playground.self) private var playground
    let message: String?

    var body: some View {
        HStack(spacing: 8) {
            switch playground.status {
            case .idle: Text("Open an image, drop one here, or choose a sample.")
            case .updating: ProgressView().controlSize(.small); Text("Updating…")
            case .ready(let s):
                Text("\(s.isFullSize ? "Full size" : "Preview") \(s.width) × \(s.height) · \(ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file)) · \(Int(s.milliseconds)) ms")
                if !s.isFullSize { Text("(preview, not the export size)").foregroundStyle(.secondary) }
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                if playground.lastGood != nil { Text("The image shown is the last good result, not this edit.").foregroundStyle(.secondary) }
            }
            Spacer()
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .font(.callout).lineLimit(2)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}
