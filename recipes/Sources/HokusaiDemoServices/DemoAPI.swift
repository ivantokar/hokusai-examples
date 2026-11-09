import Foundation
import Hokusai
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

    public init(backend: String, uploads: UploadStore = UploadStore(), hokusaiVersion: String = "2.2.2") {
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
        struct Body: Encodable { let operations: [OperationSpec]; let outputs: [Catalog.OutputSpec]; let presets: [Preset]; let targets: [String]; let samples: [Sample] }
        struct Sample: Encodable { let name: String; let title: String }
        let samples = Self.samples.map { Sample(name: $0.name, title: $0.title) }
        return try Self.encode(Body(operations: Catalog.operations, outputs: Catalog.outputs, presets: Presets.all,
                                    targets: SwiftCodeGenerator.Target.allCases.map(\.rawValue), samples: samples))
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
        struct Request: Decodable { let recipe: Recipe; let target: SwiftCodeGenerator.Target? }
        struct Response: Encodable { let code: String }
        let request = try JSONDecoder().decode(Request.self, from: body)
        return try Self.encode(Response(code: try SwiftCodeGenerator.swift(request.recipe, target: request.target ?? .core)))
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
