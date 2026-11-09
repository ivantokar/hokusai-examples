import Foundation
import Hokusai
import HokusaiPDF
import HokusaiRecipes

/// The JSON side of the HTTP API, shared by every backend so both servers answer identically.
/// A backend only routes requests here and writes the bytes back.
public struct DemoAPI: Sendable {
    public let backend: String
    public let uploads: UploadStore
    public let render: RenderService
    /// Hokusai release the package was resolved against, for display.
    public let hokusaiVersion: String

    /// The generated sample images both backends serve.
    public static let samples: [(name: String, title: String)] = [
        ("scene.png", "Scene (landscape)"), ("phone.jpg", "Phone photo (EXIF rotated)"),
        ("emblem.png", "Emblem (transparent)"), ("metadata.jpg", "Metadata fixture (EXIF, ICC, XMP, IPTC)"),
    ]
    public static let sampleNames: Set<String> = Set(samples.map(\.name)).union(["mask.png"])

    /// Where the sample pictures live, for documents that place them. `nil` means only uploads can be placed.
    public let fixtures: URL?

    public init(backend: String, uploads: UploadStore = UploadStore(), hokusaiVersion: String = "2.2.2", fixtures: URL? = nil) {
        self.fixtures = fixtures
        self.backend = backend
        self.uploads = uploads
        self.render = RenderService(uploads: uploads)
        self.hokusaiVersion = hokusaiVersion
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    // MARK: Reads

    /// The process-level settings both backends freeze at startup. The defaults are deliberately small so the
    /// Runtime Lab can show a queue filling and rejecting; set `HOKUSAI_MAX_CONCURRENT` and
    /// `HOKUSAI_MAX_QUEUED` to change them (they are read once: the runtime cannot be reconfigured later).
    public static func runtimeConfiguration(environment: [String: String] = ProcessInfo.processInfo.environment) -> RuntimeConfiguration {
        let concurrent = environment["HOKUSAI_MAX_CONCURRENT"].flatMap(Int.init).map { max(1, $0) } ?? 2
        let queued = environment["HOKUSAI_MAX_QUEUED"].flatMap(Int.init).map { max(0, $0) } ?? 2
        return RuntimeConfiguration(maxConcurrentEvaluations: .fixed(concurrent), maxQueuedEvaluations: queued)
    }

    public func backendJSON() throws -> Data {
        struct Body: Encodable { let backend: String; let hokusai: String; let recipeVersion: Int }
        return try Self.encode(Body(backend: backend, hokusai: hokusaiVersion, recipeVersion: Recipe.currentVersion))
    }

    public func catalogJSON() throws -> Data {
        struct Output: Encodable {
            let format: String; let title: String; let mime: String; let fileExtension: String; let params: [ParamSpec]
            /// `false` when this process's libvips cannot encode the format; the reason says what to install.
            let available: Bool; let reason: String?
            /// Whether browsers show this format themselves; when not, the UI asks for a labelled PNG proxy.
            let browserViewable: Bool
        }
        struct VectorPreset: Encodable { let id: String; let title: String; let document: VectorDocumentSpec }
        struct Body: Encodable {
            let operations: [OperationSpec]; let outputs: [Output]; let presets: [Preset]; let targets: [String]; let samples: [Sample]
            let vectorItems: [VectorItemSpec]; let vectorPresets: [VectorPreset]; let vectorAssets: [Choice]
        }
        let encodable = (try? Hokusai.capabilities())?.outputFormats ?? []
        let outputs = Catalog.outputs.map { o in
            let supported = encodable.contains { String(describing: $0) == o.format }
            return Output(format: o.format, title: o.title, mime: o.mime, fileExtension: o.fileExtension, params: o.params, available: supported,
                          reason: supported ? nil : "This libvips build has no \(o.title) encoder. Install one (for example libheif with an HEVC or AV1 plugin) and restart.",
                          browserViewable: RenderService.browserCanShow.contains(o.mime))
        }
        struct Sample: Encodable { let name: String; let title: String }
        let samples = Self.samples.map { Sample(name: $0.name, title: $0.title) }
        return try Self.encode(Body(operations: Catalog.operations, outputs: outputs, presets: Presets.all,
                                    targets: SwiftCodeGenerator.Target.allCases.map(\.rawValue), samples: samples,
                                    vectorItems: VectorCatalog.items,
                                    vectorPresets: VectorPresets.all.map { VectorPreset(id: $0.id, title: $0.title, document: $0.doc) },
                                    vectorAssets: vectorAssetChoices.map { Choice(value: $0.0, label: $0.1) }))
    }

    /// What this process's libvips can actually do. Codec support is reported, never inferred.
    public func capabilitiesJSON() throws -> Data {
        let caps = try Hokusai.capabilities()
        struct Body: Encodable {
            let libvips: String; let cairo: String; let input: [String]; let output: [String]; let blockedInput: [String]
            let text: Bool; let pngPalette: Bool
        }
        func names(_ set: Set<ImageFormat>) -> [String] { set.map { String(describing: $0) }.sorted() }
        return try Self.encode(Body(libvips: caps.libvipsVersion, cairo: caps.cairoVersion, input: names(caps.inputFormats),
                                    output: names(caps.outputFormats), blockedInput: names(caps.blockedInputFormats),
                                    text: caps.textRendering, pngPalette: caps.pngPalette))
    }

    public func statusJSON() async throws -> Data {
        let status = Hokusai.runtimeStatus
        let count = await uploads.count
        let bytes = await uploads.totalBytes
        let config = status.configuration
        struct Limits: Encodable { let maxQueued: Int?; let vipsConcurrency: String; let maxOutputPixels: Int?; let blockUntrusted: Bool; let uploadLimitBytes: Int; let uploadTotalBytes: Int; let uploadMaxEntries: Int; let uploadLifetimeSeconds: Int }
        struct Body: Encodable { let active: Int; let queued: Int; let maxConcurrent: Int; let frozen: Bool; let uploads: Int; let uploadBytes: Int; let limits: Limits }
        let u = uploads.limits
        return try Self.encode(Body(active: status.activeEvaluations, queued: status.queuedEvaluations, maxConcurrent: status.maxConcurrentEvaluations,
                                    frozen: status.isConfigurationFrozen, uploads: count, uploadBytes: bytes,
                                    limits: Limits(maxQueued: config.maxQueuedEvaluations, vipsConcurrency: String(describing: config.vipsConcurrency),
                                                   maxOutputPixels: config.maxOutputPixels, blockUntrusted: config.blockUntrustedOperations,
                                                   uploadLimitBytes: u.maxUploadBytes, uploadTotalBytes: u.maxTotalBytes, uploadMaxEntries: u.maxEntries,
                                                   uploadLifetimeSeconds: Int(u.timeToLive.components.seconds))))
    }

    // MARK: Writes

    public func upload(_ data: Data) async throws -> Data {
        let metadata = try await Hokusai(data: data).metadata()     // decodes the header, so a non-image fails here
        let id = try await uploads.put(data)
        struct Body: Encodable { let uploadId: String; let width: Int; let height: Int; let orientedWidth: Int; let orientedHeight: Int; let format: String?; let bytes: Int }
        return try Self.encode(Body(uploadId: id, width: metadata.width, height: metadata.height,
                                    orientedWidth: metadata.orientedSize.width, orientedHeight: metadata.orientedSize.height,
                                    format: metadata.format.map { String(describing: $0) }, bytes: data.count))
    }

    // MARK: PDF and encoders

    public struct PDFRequest: Decodable, Sendable {
        public var uploadId: String?
        public var document: VectorDocumentSpec
        /// 1-based page to return as a PNG preview instead of the PDF.
        public var previewPage: Int?
        /// Also return the Swift for the document (a separate endpoint is not needed).
        public init(uploadId: String? = nil, document: VectorDocumentSpec, previewPage: Int? = nil) { self.uploadId = uploadId; self.document = document; self.previewPage = previewPage }
    }

    public struct PDFResult: Sendable {
        public let data: Data
        public let mime: String
        public let pages: Int
        public let pdfBytes: Int
        /// A heuristic: the PDF carries a text font with a character map, which Cairo writes for text and never for pixels.
        /// The unit tests confirm it with a real PDF reader.
        public let hasSelectableText: Bool
        public let milliseconds: Double
        public func headers(backend: String) -> [String: String] {
            ["Content-Type": mime, "Cache-Control": "no-store", "X-Hokusai-Backend": backend, "X-Hokusai-Pdf-Pages": String(pages), "X-Hokusai-Bytes": String(pdfBytes),
             "X-Hokusai-Selectable-Text": hasSelectableText ? "true" : "false", "Server-Timing": "render;dur=\(String(format: "%.1f", milliseconds))",
             "Access-Control-Expose-Headers": "X-Hokusai-Pdf-Pages, X-Hokusai-Bytes, X-Hokusai-Selectable-Text, X-Hokusai-Backend, Server-Timing"]
        }
    }

    public func decodePDFRequest(_ body: Data) throws -> PDFRequest { try JSONDecoder().decode(PDFRequest.self, from: body) }

    public func pdf(_ request: PDFRequest) async throws -> PDFResult {
        let started = ContinuousClock.now
        let upload: Data? = if let id = request.uploadId { await uploads.get(id) } else { nil }
        let fixtures = fixtures
        let document = try VectorCompiler.compile(request.document) { name in
            if name == "upload" {
                guard let upload else { throw VectorError.noUpload }
                return try Hokusai(data: upload)
            }
            guard let fixtures, vectorAssetChoices.contains(where: { $0.0 == name }), name != "upload" else { throw VectorError.unknownAsset(name) }
            return try Hokusai(url: fixtures.appending(path: name))
        }
        let output = try await document.data()
        let selectable = output.data.range(of: Data("/ToUnicode".utf8)) != nil
        var data = output.data, mime = "application/pdf"
        if let page = request.previewPage {
            guard (1...output.info.pageCount).contains(page) else { throw VectorError.tooManyPages }
            do { data = try await Hokusai(data: output.data, options: InputOptions(page: page - 1)).png().data().data }
            catch is HokusaiError { throw RenderError.previewUnavailable("application/pdf") }
            mime = "image/png"
        }
        let elapsed = ContinuousClock.now - started
        return PDFResult(data: data, mime: mime, pages: output.info.pageCount, pdfBytes: output.data.count, hasSelectableText: selectable,
                         milliseconds: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }

    /// The same recipe through every encoder this runtime has, with default options, so sizes can be compared.
    /// Each one is encoded for real; the result is reduced to `maxEdge` first to keep the comparison bounded.
    public func compare(uploadId: String, recipe: Recipe, maxEdge: Int = 2048) async throws -> Data {
        struct Row: Encodable { let format: String; let title: String; let ok: Bool; let bytes: Int?; let width: Int?; let height: Int?; let milliseconds: Double?; let error: String?; let mime: String? }
        struct Body: Encodable { let rows: [Row]; let scaledTo: Int }
        var rows: [Row] = []
        for out in Catalog.outputs where out.format != "pdf" {
            var r = recipe
            r.output = OutputSettings(format: out.format)
            do {
                let result = try await render.render(RenderRequest(uploadId: uploadId, recipe: r, previewMaxEdge: maxEdge))
                rows.append(Row(format: out.format, title: out.title, ok: true, bytes: result.data.count, width: result.width, height: result.height, milliseconds: result.serverMilliseconds, error: nil, mime: result.mime))
            } catch let error as HokusaiError {
                rows.append(Row(format: out.format, title: out.title, ok: false, bytes: nil, width: nil, height: nil, milliseconds: nil, error: error.errorDescription ?? "failed", mime: nil))
            }
        }
        return try Self.encode(Body(rows: rows, scaledTo: maxEdge))
    }

    // MARK: Inspect

    private struct Facts: Encodable {
        let format: String?; let width: Int; let height: Int; let orientedWidth: Int; let orientedHeight: Int
        let orientation: Int?; let channels: Int; let hasAlpha: Bool; let interpretation: String; let sampleFormat: String
        let bitsPerSample: Int?; let isPalette: Bool?; let density: String?; let pages: Int; let animated: Bool
        let frames: Int?; let progressive: Bool?; let chroma: String?; let bytes: Int
        /// Sizes in bytes of the embedded blocks; 0 means the block is absent.
        let exifBytes: Int; let iccBytes: Int; let xmpBytes: Int; let iptcBytes: Int
    }

    private static func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }

    private static func facts(_ m: ImageMetadata, bytes: Int) -> Facts {
        Facts(format: m.format.map { String(describing: $0) }, width: m.width, height: m.height,
              orientedWidth: m.orientedSize.width, orientedHeight: m.orientedSize.height, orientation: m.orientation?.rawValue,
              channels: m.pixel.channels, hasAlpha: m.pixel.hasAlpha, interpretation: String(describing: m.pixel.interpretation),
              sampleFormat: String(describing: m.pixel.sampleFormat), bitsPerSample: m.pixel.bitsPerSample, isPalette: m.pixel.isPalette,
              density: m.density.map { "\(format($0.horizontal)) × \(format($0.vertical))\(m.densityUnit.map { " \(String(describing: $0))" } ?? "")" }, pages: m.pages.count, animated: m.isAnimated,
              frames: m.animation?.frameDelays.count, progressive: m.isProgressive, chroma: m.chromaSubsampling, bytes: m.sourceByteSize ?? bytes,
              exifBytes: m.exif?.count ?? 0, iccBytes: m.iccProfile?.count ?? 0, xmpBytes: m.xmp?.count ?? 0, iptcBytes: m.iptc?.count ?? 0)
    }

    /// Facts about the original upload and, when a recipe is given, about the bytes that recipe actually
    /// exports. The output is encoded and read back, so what is shown is what a file would contain and
    /// not what the settings promise.
    public func inspect(uploadId: String, recipe: Recipe?) async throws -> Data {
        guard let bytes = await uploads.get(uploadId) else { throw RenderError.unknownUpload }
        struct Body: Encodable { let source: Facts; let output: Facts?; let outputFormat: String? }
        let source = Self.facts(try await Hokusai(data: bytes).metadata(), bytes: bytes.count)
        var output: Facts?
        if let recipe {
            let rendered = try await render.render(RenderRequest(uploadId: uploadId, recipe: recipe))
            output = Self.facts(try await Hokusai(data: rendered.data).metadata(), bytes: rendered.data.count)
        }
        return try Self.encode(Body(source: source, output: output, outputFormat: recipe?.output.format))
    }

    public func decodeRenderRequest(_ body: Data) throws -> RenderRequest {
        try JSONDecoder().decode(RenderRequest.self, from: body)
    }

    public func code(_ body: Data) throws -> Data {
        struct Request: Decodable { let recipe: Recipe?; let document: VectorDocumentSpec?; let target: SwiftCodeGenerator.Target? }
        struct Response: Encodable { let code: String }
        let request = try JSONDecoder().decode(Request.self, from: body)
        if let document = request.document { return try Self.encode(Response(code: try VectorCodeGenerator.swift(document))) }
        guard let recipe = request.recipe else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "send a recipe or a document")) }
        return try Self.encode(Response(code: try SwiftCodeGenerator.swift(recipe, target: request.target ?? .core)))
    }

    // MARK: Errors

    public struct Failure: Sendable { public let status: Int; public let code: String; public let message: String }

    /// The status and message for the errors this package throws. `HokusaiError` is mapped by each
    /// adapter's own `httpStatus`, which is the integration being demonstrated, so it returns `nil` here.
    public static func failure(for error: Error) -> Failure? {
        switch error {
        case let e as RecipeError: Failure(status: 422, code: "recipe", message: e.description)
        case let e as UploadStore.StoreError:
            switch e {
            case .tooLarge(let limit): Failure(status: 413, code: "tooLarge", message: "The image is larger than \(limit / 1_048_576) MiB.")
            case .empty: Failure(status: 400, code: "empty", message: "The upload is empty.")
            }
        case RenderError.unknownUpload: Failure(status: 404, code: "expiredUpload", message: "That upload has expired or never existed. Open the image again.")
        case let e as VectorError: Failure(status: 422, code: "document", message: e.description)
        case RenderError.previewUnavailable(let mime): Failure(status: 501, code: "previewUnavailable", message: "This server's libvips cannot read \(mime) back, so it cannot draw a preview of it. The file itself can still be exported; the Docker image includes poppler for PDF previews.")
        case RenderError.unknownStep: Failure(status: 422, code: "recipe", message: "The step to stop before is not in the recipe.")
        case RenderError.invalidPreviewSize: Failure(status: 400, code: "previewSize", message: "previewMaxEdge must be between 16 and 4096.")
        case is DecodingError: Failure(status: 400, code: "badRequest", message: "The request body is not valid JSON for this endpoint.")
        default: nil
        }
    }

    /// In this API the recipe is user input, so a transform that cannot apply to this image (a crop
    /// outside the pixels, say) is the client's to fix. The adapters map `.transform` to 500 because for
    /// a server's own pipeline it is a bug; this returns 422 for it and `nil` for everything else.
    public static func recipeStatus(for error: HokusaiError) -> Int? {
        if case .transform = error { return 422 }
        return nil
    }

    public static func errorJSON(code: String, message: String) -> Data {
        struct Body: Encodable { struct Inner: Encodable { let code: String; let message: String }; let error: Inner }
        return (try? encode(Body(error: .init(code: code, message: message)))) ?? Data("{}".utf8)
    }
}
