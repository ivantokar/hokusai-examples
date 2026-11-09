import Foundation
import Hokusai
import HokusaiRecipes

public struct RenderRequest: Codable, Sendable {
    public var uploadId: String
    public var recipe: Recipe
    /// When set, the *result* is reduced to fit this many pixels on its longest side, for display.
    /// The recipe is evaluated on the full original either way, so geometry steps stay exact.
    public var previewMaxEdge: Int?
    /// When set, only the enabled steps *before* the step with this id run. The crop editor uses it to
    /// show the image that enters a crop, in the coordinates the crop is expressed in.
    public var stopBefore: String?
    /// Ask for something a browser can show: if the encoded format is one browsers do not display (TIFF, HEIF,
    /// PDF) the response is a PNG proxy decoded from the real bytes, labelled as such. The real artifact is
    /// what a request without this flag returns.
    public var viewable: Bool?
    /// Zero-based page of a multipage input (PDF pages, GIF frames), as `InputOptions.page` takes it.
    public var page: Int?

    public init(uploadId: String, recipe: Recipe, previewMaxEdge: Int? = nil, stopBefore: String? = nil, viewable: Bool? = nil, page: Int? = nil) {
        self.uploadId = uploadId
        self.recipe = recipe
        self.previewMaxEdge = previewMaxEdge
        self.stopBefore = stopBefore
        self.viewable = viewable
        self.page = page
    }
}

public struct RenderResult: Sendable {
    public let data: Data
    public let mime: String
    public let fileExtension: String
    public let width: Int
    public let height: Int
    /// Time spent evaluating and encoding in the server process, excluding network time.
    public let serverMilliseconds: Double
    /// Set when `data` is a PNG standing in for a format the browser cannot show; the real facts follow.
    public var proxyOf: String?
    public var realBytes: Int?
    public var pdfPages: Int?
    public var pdfWidth: Double?
    public var pdfHeight: Double?

    /// The `X-Hokusai-*` and `Server-Timing` headers every backend sends with a render, so they cannot differ.
    public func headers(backend: String) -> [String: String] {
        var h = [
            "Content-Type": mime, "Cache-Control": "no-store",
            "X-Hokusai-Width": String(width), "X-Hokusai-Height": String(height),
            "X-Hokusai-Bytes": String(realBytes ?? data.count), "X-Hokusai-Backend": backend,
            "Server-Timing": "render;dur=\(String(format: "%.1f", serverMilliseconds))",
        ]
        var exposed = ["X-Hokusai-Width", "X-Hokusai-Height", "X-Hokusai-Bytes", "X-Hokusai-Backend", "Server-Timing"]
        func add(_ name: String, _ value: String?) { if let value { h[name] = value; exposed.append(name) } }
        add("X-Hokusai-Proxy-Of", proxyOf)
        add("X-Hokusai-Pdf-Pages", pdfPages.map(String.init))
        add("X-Hokusai-Pdf-Width", pdfWidth.map { String($0) })
        add("X-Hokusai-Pdf-Height", pdfHeight.map { String($0) })
        h["Access-Control-Expose-Headers"] = exposed.joined(separator: ", ")
        return h
    }
}

public enum RenderError: Error {
    case unknownUpload
    case invalidPreviewSize
    case unknownStep
    /// This libvips cannot read the format back, so there is nothing to build a preview from.
    case previewUnavailable(String)
}

/// Runs recipes for any HTTP framework. The servers adapt requests to this and responses from it.
public struct RenderService: Sendable {
    /// Formats every current browser displays itself. Anything else gets a proxy when the caller asks for one.
    static let browserCanShow: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif", "image/avif"]

    public let uploads: UploadStore
    public init(uploads: UploadStore) { self.uploads = uploads }

    public func render(_ request: RenderRequest) async throws -> RenderResult {
        if let edge = request.previewMaxEdge, !(16...4096).contains(edge) { throw RenderError.invalidPreviewSize }
        guard let bytes = await uploads.get(request.uploadId) else { throw RenderError.unknownUpload }
        let started = ContinuousClock.now
        // Decoding is lazy: invalid bytes are reported when the terminal runs, as a HokusaiError.
        var inputOptions = InputOptions()
        inputOptions.page = request.page
        let source = try Hokusai(data: bytes, options: inputOptions)
        var recipe = request.recipe
        if let stop = request.stopBefore {
            guard let index = recipe.steps.firstIndex(where: { $0.id == stop }) else { throw RenderError.unknownStep }
            recipe.steps = Array(recipe.steps[..<index])
        }
        let compiled = try RecipeCompiler.compile(recipe, source: source, fitting: request.previewMaxEdge)
        let output = try await compiled.pipeline.data()
        var result = RenderResult(data: output.data, mime: compiled.mime, fileExtension: compiled.fileExtension,
                                  width: output.info.width, height: output.info.height, serverMilliseconds: 0)
        result.pdfPages = output.info.pdf?.pageCount
        result.pdfWidth = output.info.pdf?.pageWidth
        result.pdfHeight = output.info.pdf?.pageHeight
        if request.viewable == true, !RenderService.browserCanShow.contains(compiled.mime) {
            // Decode what was really produced (page 1 for a PDF) and show that, so the proxy is the artifact seen
            // through this runtime's decoder, not a separate rendering of the pipeline.
            let proxy: Output
            do { proxy = try await Hokusai(data: output.data, options: InputOptions(page: 0)).png().data() }
            catch let error as HokusaiError {
                if case .unsupported = error { throw RenderError.previewUnavailable(compiled.mime) }
                if case .decode = error { throw RenderError.previewUnavailable(compiled.mime) }
                throw error
            }
            result = RenderResult(data: proxy.data, mime: "image/png", fileExtension: "png", width: proxy.info.width, height: proxy.info.height,
                                  serverMilliseconds: 0, proxyOf: compiled.mime, realBytes: output.data.count,
                                  pdfPages: result.pdfPages, pdfWidth: result.pdfWidth, pdfHeight: result.pdfHeight)
        }
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return RenderResult(data: result.data, mime: result.mime, fileExtension: result.fileExtension, width: result.width, height: result.height,
                            serverMilliseconds: ms, proxyOf: result.proxyOf, realBytes: result.realBytes,
                            pdfPages: result.pdfPages, pdfWidth: result.pdfWidth, pdfHeight: result.pdfHeight)
    }
}
