import Foundation
import Hokusai
import HokusaiDemoServices
import HokusaiHummingbird
import HokusaiRecipes
import HTTPTypes
import Hummingbird

// The same API as the Vapor backend, so one Web UI works with either. Only the HTTP layer differs.

let backend = "hummingbird"
let host = ProcessInfo.processInfo.environment["HOST"] ?? "127.0.0.1"
let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "") ?? 8082
let webRoot = ProcessInfo.processInfo.environment["WEB_ROOT"] ?? "../web"
let fixturesRoot = ProcessInfo.processInfo.environment["FIXTURES_ROOT"] ?? "../fixtures"

func jsonResponse(_ data: Data, status: HTTPResponse.Status = .ok) -> Response {
    Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"], body: .init(byteBuffer: ByteBuffer(data: data)))
}

func failure(_ error: Error) -> Response {
    if let error = error as? HokusaiError {
        return jsonResponse(DemoAPI.errorJSON(code: "hokusai", message: error.errorDescription ?? "Image processing failed"), status: DemoAPI.recipeStatus(for: error).map { HTTPResponse.Status(code: $0) } ?? error.httpStatus)
    }
    if let failure = DemoAPI.failure(for: error) {
        return jsonResponse(DemoAPI.errorJSON(code: failure.code, message: failure.message), status: HTTPResponse.Status(code: failure.status))
    }
    return jsonResponse(DemoAPI.errorJSON(code: "internal", message: "Something went wrong."), status: .internalServerError)
}

let widthField = HTTPField.Name("X-Hokusai-Width")!
let heightField = HTTPField.Name("X-Hokusai-Height")!
let bytesField = HTTPField.Name("X-Hokusai-Bytes")!
let backendField = HTTPField.Name("X-Hokusai-Backend")!
let timingField = HTTPField.Name("Server-Timing")!
let exposeField = HTTPField.Name("Access-Control-Expose-Headers")!

func collect(_ request: Request, limit: Int) async throws -> Data {
    Data(buffer: try await request.body.collect(upTo: limit))
}

func buildRouter(api: DemoAPI) -> Router<BasicRequestContext> {
    let router = Router()

    // MARK: The minimal integration
    //
    // An upload becomes a pipeline, the pipeline is transformed and streamed back.
    // Everything else in this file is the demo around it.
    //
    //     curl --data-binary @photo.jpg 'http://localhost:8082/api/minimal/resize?width=800' -o small.webp
    router.group("api/minimal").add(middleware: HokusaiErrorMiddleware()).post("resize") { request, _ -> Response in
        let width = min(max(request.uri.queryParameters["width"].flatMap { Int($0) } ?? 800, 16), 4096)
        let image = try await request.hokusaiImage(maximumSize: 5 * 1024 * 1024)       // 413 above 5 MiB
        return try await image
            .autoOrient()
            .resize(width: width, fit: .inside)
            .webp(quality: 82)
            .response()                                                                // Content-Type: image/webp, streamed
    }

    // MARK: The demo API (shared behaviour lives in HokusaiDemoServices)
    let apiRoutes = router.group("api")
    apiRoutes.get("backend") { _, _ in jsonResponse(try api.backendJSON()) }
    apiRoutes.get("catalog") { _, _ in jsonResponse(try api.catalogJSON()) }
    apiRoutes.get("capabilities") { _, _ in jsonResponse(try api.capabilitiesJSON()) }
    apiRoutes.get("status") { _, _ in jsonResponse(try await api.statusJSON()) }

    apiRoutes.post("uploads") { request, _ -> Response in
        do {
            let limit = await api.uploads.limits.maxUploadBytes
            if let declared = request.headers[.contentLength].flatMap({ Int($0) }), declared > limit { throw UploadStore.StoreError.tooLarge(limit: limit) }
            return jsonResponse(try await api.upload(try await collect(request, limit: limit)), status: .created)
        } catch let error as HTTPError where error.status == .contentTooLarge {
            return failure(UploadStore.StoreError.tooLarge(limit: await api.uploads.limits.maxUploadBytes))
        } catch { return failure(error) }
    }
    apiRoutes.post("code") { request, _ -> Response in
        do { return jsonResponse(try api.code(try await collect(request, limit: 1 << 20))) } catch { return failure(error) }
    }
    apiRoutes.post("render") { request, _ -> Response in
        do {
            let result = try await api.render.render(try api.decodeRenderRequest(try await collect(request, limit: 1 << 20)))
            return Response(status: .ok, headers: [
                .contentType: result.mime, .cacheControl: "no-store",
                widthField: String(result.width), heightField: String(result.height), bytesField: String(result.data.count),
                backendField: api.backend, timingField: "render;dur=\(String(format: "%.1f", result.serverMilliseconds))",
                exposeField: "X-Hokusai-Width, X-Hokusai-Height, X-Hokusai-Bytes, X-Hokusai-Backend, Server-Timing",
            ], body: .init(byteBuffer: ByteBuffer(data: result.data)))
        } catch { return failure(error) }
    }

    // The sample images are plain files shared by both backends.
    router.get("samples/:name") { _, context -> Response in
        let name = try context.parameters.require("name")
        guard ["scene.png", "phone.jpg", "emblem.png", "mask.png"].contains(name),
              let data = FileManager.default.contents(atPath: "\(fixturesRoot)/\(name)") else { throw HTTPError(.notFound) }
        let type = name.hasSuffix(".jpg") ? "image/jpeg" : "image/png"
        return Response(status: .ok, headers: [.contentType: type, .cacheControl: "public, max-age=3600"], body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    // The web UI. Registered last so it never shadows an API route.
    router.add(middleware: FileMiddleware(webRoot, searchForIndexHtml: true))
    return router
}

// Hokusai's process-level settings are frozen at first use, so set them before the first request.
try Hokusai.configure(.init(maxConcurrentEvaluations: .fixed(4), maxQueuedEvaluations: 64))
try Hokusai.initialize()

let app = Application(router: buildRouter(api: DemoAPI(backend: backend)), configuration: .init(address: .hostname(host, port: port)))
try await app.runService()
