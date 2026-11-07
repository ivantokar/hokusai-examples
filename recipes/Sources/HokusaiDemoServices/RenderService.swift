import Foundation
import Hokusai
import HokusaiRecipes

public struct RenderRequest: Codable, Sendable {
    public var uploadId: String
    public var recipe: Recipe
    /// When set, the *result* is reduced to fit this many pixels on its longest side, for display.
    /// The recipe is evaluated on the full original either way, so geometry steps stay exact.
    public var previewMaxEdge: Int?
}

public struct RenderResult: Sendable {
    public let data: Data
    public let mime: String
    public let fileExtension: String
    public let width: Int
    public let height: Int
    /// Time spent evaluating and encoding in the server process, excluding network time.
    public let serverMilliseconds: Double
}

public enum RenderError: Error {
    case unknownUpload
    case invalidPreviewSize
}

/// Runs recipes for any HTTP framework. The servers adapt requests to this and responses from it.
public struct RenderService: Sendable {
    public let uploads: UploadStore
    public init(uploads: UploadStore) { self.uploads = uploads }

    public func render(_ request: RenderRequest) async throws -> RenderResult {
        if let edge = request.previewMaxEdge, !(16...4096).contains(edge) { throw RenderError.invalidPreviewSize }
        guard let bytes = await uploads.get(request.uploadId) else { throw RenderError.unknownUpload }
        let started = ContinuousClock.now
        // Decoding is lazy: invalid bytes are reported when the terminal runs, as a HokusaiError.
        let source = try Hokusai(data: bytes)
        let compiled = try RecipeCompiler.compile(request.recipe, source: source, fitting: request.previewMaxEdge)
        let output = try await compiled.pipeline.data()
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return RenderResult(data: output.data, mime: compiled.mime, fileExtension: compiled.fileExtension,
                            width: output.info.width, height: output.info.height, serverMilliseconds: ms)
    }
}
