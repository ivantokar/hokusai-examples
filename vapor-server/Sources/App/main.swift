import Foundation
import Hokusai
import HokusaiDemoServices
import HokusaiVapor
import HokusaiRecipes
import Vapor

// MARK: - The minimal integration
//
// This is the whole integration the library is about: an upload becomes a pipeline, the pipeline
// is transformed and streamed back. Everything else in this file is the demo around it.
//
//     curl --data-binary @photo.jpg 'http://localhost:8081/api/minimal/resize?width=800' -o small.webp
func minimalRoutes(_ routes: RoutesBuilder) {
    routes.grouped(HokusaiErrorMiddleware()).post("api", "minimal", "resize") { req async throws -> Response in
        let width = min(max(req.query[Int.self, at: "width"] ?? 800, 16), 4096)
        let image = try await req.hokusaiImage(maximumSize: 5 * 1024 * 1024)  // 413 above 5 MiB
            .autoOrient()
            .resize(width: width, fit: .inside)
        // ?format= is only here for the Runtime Lab: TIFF is encoded in memory before the first byte leaves.
        switch req.query[String.self, at: "format"] {
        case "jpeg": return try await image.jpeg(quality: 85).response()
        case "png": return try await image.png().response()
        case "tiff": return try await image.tiff().response()
        default: return try await image.webp(quality: 82).response()          // Content-Type: image/webp, streamed
        }
    }
}

// MARK: - The demo API (shared behaviour lives in HokusaiDemoServices)

func demoRoutes(_ app: Application, api: DemoAPI) {
    let routes = app.grouped("api")

    func json(_ data: Data, status: HTTPStatus = .ok) -> Response {
        Response(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: .init(data: data))
    }
    func fail(_ error: Error) -> Response {
        if let error = error as? HokusaiError {
            return json(DemoAPI.errorJSON(code: "hokusai", message: error.errorDescription ?? "Image processing failed"), status: DemoAPI.recipeStatus(for: error).map { HTTPStatus(statusCode: $0) } ?? error.httpStatus)
        }
        app.logger.debug("\(error)")
        if let failure = DemoAPI.failure(for: error) {
            return json(DemoAPI.errorJSON(code: failure.code, message: failure.message), status: HTTPStatus(statusCode: failure.status))
        }
        app.logger.error("\(error)")
        return json(DemoAPI.errorJSON(code: "internal", message: "Something went wrong."), status: .internalServerError)
    }
    func body(_ req: Request) -> Data { Data(buffer: req.body.data ?? ByteBuffer()) }

    routes.get("backend") { _ in json(try api.backendJSON()) }
    routes.get("catalog") { _ in json(try api.catalogJSON()) }
    routes.get("capabilities") { _ in json(try api.capabilitiesJSON()) }
    routes.get("status") { _ in json(try await api.statusJSON()) }

    routes.on(.POST, "uploads", body: .collect(maxSize: "26mb")) { req async -> Response in
        do { return json(try await api.upload(body(req)), status: .created) } catch { return fail(error) }
    }
    routes.post("code") { req async -> Response in
        do { return json(try api.code(body(req))) } catch { return fail(error) }
    }
    routes.post("inspect") { req async -> Response in
        struct Body: Decodable { let uploadId: String; let recipe: Recipe?; let page: Int? }
        do {
            let body = try JSONDecoder().decode(Body.self, from: body(req))
            return json(try await api.inspect(uploadId: body.uploadId, recipe: body.recipe, page: body.page))
        } catch { return fail(error) }
    }
    routes.post("render") { req async -> Response in
        do {
            let result = try await api.render.render(try api.decodeRenderRequest(body(req)))
            return Response(status: .ok, headers: HTTPHeaders(result.headers(backend: api.backend).map { ($0.key, $0.value) }), body: .init(data: result.data))
        } catch { return fail(error) }
    }
    routes.post("raw", "output") { req async -> Response in
        do {
            let result = try await api.rawOutput(try api.decodeRawOutputRequest(body(req)))
            return Response(status: .ok, headers: HTTPHeaders(result.headers(backend: api.backend).map { ($0.key, $0.value) }), body: .init(data: result.data))
        } catch { return fail(error) }
    }
    routes.post("raw", "input") { req async -> Response in
        do {
            let input = try DemoAPI.RawInput(query: { req.query[String.self, at: $0] })
            let result = try await api.rawInput(input, data: body(req))
            return Response(status: .ok, headers: HTTPHeaders(result.headers(backend: api.backend).map { ($0.key, $0.value) }), body: .init(data: result.png))
        } catch { return fail(error) }
    }
    routes.post("pdf") { req async -> Response in
        do {
            let result = try await api.pdf(try api.decodePDFRequest(body(req)))
            return Response(status: .ok, headers: HTTPHeaders(result.headers(backend: api.backend).map { ($0.key, $0.value) }), body: .init(data: result.data))
        } catch { return fail(error) }
    }
    routes.post("compare") { req async -> Response in
        struct Body: Decodable { let uploadId: String; let recipe: Recipe; let page: Int? }
        do {
            let body = try JSONDecoder().decode(Body.self, from: body(req))
            return json(try await api.compare(uploadId: body.uploadId, recipe: body.recipe, page: body.page))
        } catch { return fail(error) }
    }
}

// MARK: - Startup

func configure(_ app: Application) throws {
    // Hokusai's process-level settings are frozen at first use, so set them before the first request.
    try app.hokusai.configure(DemoAPI.runtimeConfiguration())

    // Vapor collects request bodies up to this size; the minimal route and the upload route check their own limits too.
    app.routes.defaultMaxBodySize = "26mb"

    let fixtures = Environment.get("FIXTURES_ROOT") ?? "../fixtures"
    let api = DemoAPI(backend: "vapor", fixtures: URL(fileURLWithPath: fixtures))
    minimalRoutes(app)
    demoRoutes(app, api: api)

    // The web UI and the sample images are plain files shared by both backends.
    let root = Environment.get("WEB_ROOT") ?? "../web"
    app.middleware.use(FileMiddleware(publicDirectory: root, defaultFile: "index.html"))
    app.get("samples", ":name") { req async throws -> Response in
        let name = try req.parameters.require("name")
        guard DemoAPI.sampleNames.contains(name) else { throw Abort(.notFound) }
        return try await req.fileio.asyncStreamFile(at: "\(fixtures)/\(name)")
    }
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "127.0.0.1"
    app.http.server.configuration.port = Int(Environment.get("PORT") ?? "") ?? 8081
}

@main
enum Entry {
    static func main() async throws {
        let app = try await Application.make(.detect())
        try configure(app)
        try await app.execute()
        try await app.asyncShutdown()
    }
}
