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

    public func backendJSON() throws -> Data {
        struct Body: Encodable { let backend: String; let hokusai: String; let recipeVersion: Int }
        return try Self.encode(Body(backend: backend, hokusai: hokusaiVersion, recipeVersion: Recipe.currentVersion))
    }

    public func catalogJSON() throws -> Data {
        struct Body: Encodable { let operations: [OperationSpec]; let outputs: [Catalog.OutputSpec]; let presets: [Preset]; let targets: [String]; let samples: [Sample] }
        struct Sample: Encodable { let name: String; let title: String }
        let samples = [Sample(name: "scene.png", title: "Scene (landscape)"), Sample(name: "phone.jpg", title: "Phone photo (EXIF rotated)"),
                       Sample(name: "emblem.png", title: "Emblem (transparent)")]
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
        struct Body: Encodable { let active: Int; let queued: Int; let maxConcurrent: Int; let frozen: Bool; let uploads: Int; let uploadBytes: Int }
        return try Self.encode(Body(active: status.activeEvaluations, queued: status.queuedEvaluations, maxConcurrent: status.maxConcurrentEvaluations,
                                    frozen: status.isConfigurationFrozen, uploads: count, uploadBytes: bytes))
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
