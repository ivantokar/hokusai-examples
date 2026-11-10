import Foundation
import Hokusai
import HokusaiRecipes

public struct RenderRequest: Codable, Sendable {
    /// Absent when the recipe makes its own pixels (a text source).
    public var uploadId: String?
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
    /// Names of extra pictures a recipe may use, mapped to upload ids: `["second": "<upload id>"]`.
    public var assets: [String: String]?

    public init(uploadId: String? = nil, recipe: Recipe, previewMaxEdge: Int? = nil, stopBefore: String? = nil, viewable: Bool? = nil, page: Int? = nil, assets: [String: String]? = nil) {
        self.uploadId = uploadId
        self.recipe = recipe
        self.previewMaxEdge = previewMaxEdge
        self.stopBefore = stopBefore
        self.viewable = viewable
        self.page = page
        self.assets = assets
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
    /// Where the bundled pictures live; `nil` means only uploaded pictures can be placed.
    public let fixtures: URL?
    public init(uploads: UploadStore, fixtures: URL? = nil) { self.uploads = uploads; self.fixtures = fixtures }

    /// Resolves picture names for image layers and masks: the bundled samples, and uploads named by the request.
    /// A name is only ever a key into those two sets, never a path.
    public func assets(named: [String: String]?) async -> RecipeCompiler.Assets {
        var uploaded: [String: Data] = [:]
        for (name, id) in named ?? [:] { if let data = await uploads.get(id) { uploaded[name] = data } }
        let fixtures = fixtures, uploads = uploaded
        return { name in
            if let data = uploads[name] { return try Hokusai(data: data) }
            if name == "second" { throw RecipeError.invalidParameter(operation: "image", name: "picture", reason: "“My second image” needs a second image: choose one in the step's settings") }
            guard let fixtures, layerAssetChoices.contains(where: { $0.0 == name }) else { throw RecipeError.invalidParameter(operation: "image", name: "picture", reason: "unknown picture '\(name)'") }
            return try Hokusai(url: fixtures.appending(path: name))
        }
    }

    /// The pipeline a recipe starts from: the uploaded image, or `nil` when the recipe generates its own pixels
    /// (the compiler then builds the source itself). Decoding is lazy: invalid bytes are reported when a terminal runs.
    public func input(uploadId: String?, recipe: Recipe, page: Int?) async throws -> Hokusai? {
        if recipe.source != nil { return nil }
        guard let uploadId else { throw RecipeError.invalidParameter(operation: "recipe", name: "source", reason: "send an uploadId, or give the recipe a generated source") }
        guard let bytes = await uploads.get(uploadId) else { throw RenderError.unknownUpload }
        var options = InputOptions()
        options.page = page
        return try Hokusai(data: bytes, options: options)
    }

    public func render(_ request: RenderRequest) async throws -> RenderResult {
        if let edge = request.previewMaxEdge, !(16...4096).contains(edge) { throw RenderError.invalidPreviewSize }
        let started = ContinuousClock.now
        let source = try await input(uploadId: request.uploadId, recipe: request.recipe, page: request.page)
        var recipe = request.recipe
        if let stop = request.stopBefore {
            guard let index = recipe.steps.firstIndex(where: { $0.id == stop }) else { throw RenderError.unknownStep }
            recipe.steps = Array(recipe.steps[..<index])
        }
        let assets = await assets(named: request.assets)
        let sizes = RecipeSizing.needsSizes(recipe) ? try await RecipeSizing.resolve(recipe, source: source, assets: assets) : [:]
        let compiled = try RecipeCompiler.compile(recipe, source: source, fitting: request.previewMaxEdge, assets: assets, sizes: sizes)
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
