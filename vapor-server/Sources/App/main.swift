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
        return try await req.hokusaiImage(maximumSize: 5 * 1024 * 1024)       // 413 above 5 MiB
            .autoOrient()
            .resize(width: width, fit: .inside)
            .webp(quality: 82)
            .response()                                                       // Content-Type: image/webp, streamed
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
        struct Body: Decodable { let uploadId: String; let recipe: Recipe? }
        do {
            let body = try JSONDecoder().decode(Body.self, from: body(req))
            return json(try await api.inspect(uploadId: body.uploadId, recipe: body.recipe))
        } catch { return fail(error) }
    }
    routes.post("render") { req async -> Response in
        do {
            let result = try await api.render.render(try api.decodeRenderRequest(body(req)))
            return Response(status: .ok, headers: [
                "Content-Type": result.mime, "Cache-Control": "no-store",
                "X-Hokusai-Width": String(result.width), "X-Hokusai-Height": String(result.height),
                "X-Hokusai-Bytes": String(result.data.count), "X-Hokusai-Backend": api.backend,
                "Server-Timing": "render;dur=\(String(format: "%.1f", result.serverMilliseconds))",
                "Access-Control-Expose-Headers": "X-Hokusai-Width, X-Hokusai-Height, X-Hokusai-Bytes, X-Hokusai-Backend, Server-Timing",
            ], body: .init(data: result.data))
        } catch { return fail(error) }
    }
}

// MARK: - Startup

func configure(_ app: Application) throws {
    // Hokusai's process-level settings are frozen at first use, so set them before the first request.
    try app.hokusai.configure(.init(maxConcurrentEvaluations: .fixed(4), maxQueuedEvaluations: 64))

    // Vapor collects request bodies up to this size; the minimal route and the upload route check their own limits too.
    app.routes.defaultMaxBodySize = "26mb"

    let api = DemoAPI(backend: "vapor")
    minimalRoutes(app)
    demoRoutes(app, api: api)

    // The web UI and the sample images are plain files shared by both backends.
    let root = Environment.get("WEB_ROOT") ?? "../web"
    let fixtures = Environment.get("FIXTURES_ROOT") ?? "../fixtures"
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
