import Foundation
import Hokusai

/// The public face of the catalog: what exists, and how a recipe becomes Hokusai calls and Swift code.
public enum Catalog {
    public static let maximumSteps = 40

    public static var operations: [OperationSpec] { allOperations.map(\.spec) }

    public struct OutputSpec: Codable, Sendable {
        public let format: String
        public let title: String
        public let mime: String
        public let fileExtension: String
        public let params: [ParamSpec]
    }

    public static var outputs: [OutputSpec] {
        allOutputs.map { OutputSpec(format: $0.format, title: $0.title, mime: $0.mime, fileExtension: $0.fileExtension, params: $0.format == "pdf" ? $0.params : $0.params + metadataParams) }
    }
}

public struct CompiledRecipe: Sendable {
    public let pipeline: Hokusai
    public let mime: String
    public let fileExtension: String
}

public enum RecipeCompiler {
    private static let operations = Dictionary(uniqueKeysWithValues: allOperations.map { ($0.spec.id, $0) })
    private static let outputs = Dictionary(uniqueKeysWithValues: allOutputs.map { ($0.format, $0) })

    /// Validates a recipe and applies it, in order, to `source` using ordinary public Hokusai calls.
    /// Nothing is read or decoded until the caller runs a terminal on `pipeline`.
    public static func compile(_ recipe: Recipe, source: Hokusai, fitting maxEdge: Int? = nil) throws -> CompiledRecipe {
        try validate(recipe)
        var pipeline = source
        for step in recipe.steps where step.enabled {
            let def = operations[step.op]!
            pipeline = try def.apply(pipeline, try Params(operation: step.op, specs: def.spec.params, values: step.params))
        }
        // A display-size copy of the *result*; the recipe itself is untouched, so it stays accurate.
        if let maxEdge { pipeline = try pipeline.resize(width: maxEdge, height: maxEdge, fit: .inside, withoutEnlargement: true) }
        let out = outputs[recipe.output.format]!
        let outParams = try Params(operation: recipe.output.format, specs: out.params + metadataParams, values: recipe.output.options)
        pipeline = try out.apply(applyMetadata(pipeline, outParams), outParams)
        return CompiledRecipe(pipeline: pipeline, mime: out.mime, fileExtension: out.fileExtension)
    }

    public static func validate(_ recipe: Recipe) throws {
        guard recipe.version == Recipe.currentVersion else { throw RecipeError.unsupportedVersion(recipe.version) }
        guard recipe.steps.count <= Catalog.maximumSteps else { throw RecipeError.tooManySteps(Catalog.maximumSteps) }
        for step in recipe.steps {
            guard let def = operations[step.op] else { throw RecipeError.unknownOperation(step.op) }
            _ = try Params(operation: step.op, specs: def.spec.params, values: step.params)
        }
        guard let out = outputs[recipe.output.format] else { throw RecipeError.unknownFormat(recipe.output.format) }
        _ = try Params(operation: recipe.output.format, specs: out.params + metadataParams, values: recipe.output.options)
    }
}

public enum SwiftCodeGenerator {
    private static let operations = Dictionary(uniqueKeysWithValues: allOperations.map { ($0.spec.id, $0) })
    private static let outputs = Dictionary(uniqueKeysWithValues: allOutputs.map { ($0.format, $0) })

    public enum Target: String, Codable, Sendable, CaseIterable { case core, vapor, hummingbird }

    /// The chained calls for the enabled steps and the encoder, one per line.
    public static func chain(_ recipe: Recipe) throws -> [String] {
        try RecipeCompiler.validate(recipe)
        var lines: [String] = []
        for step in recipe.steps where step.enabled {
            let def = operations[step.op]!
            lines.append(def.swift(try Params(operation: step.op, specs: def.spec.params, values: step.params)))
        }
        let out = outputs[recipe.output.format]!
        let outParams = try Params(operation: recipe.output.format, specs: out.params + metadataParams, values: recipe.output.options)
        if let policy = metadataSwift(outParams) { lines.append(policy) }
        lines.append(out.swift(outParams))
        return lines
    }

    /// Readable Swift that reproduces the final export. The source path is a placeholder: the demo's
    /// uploaded id is not a file on your machine.
    public static func swift(_ recipe: Recipe, target: Target = .core) throws -> String {
        let lines = try chain(recipe)
        let ext = outputs[recipe.output.format]!.fileExtension
        func indented(_ spaces: Int) -> String { lines.map { String(repeating: " ", count: spaces) + $0 }.joined(separator: "\n") }
        switch target {
        case .core:
            return """
            import Foundation
            import Hokusai

            let output = try await Hokusai(url: URL(fileURLWithPath: "input.jpg"))   // your source image
            \(indented(4))
                .write(to: URL(fileURLWithPath: "result.\(ext)"))

            print("Wrote \\(output.width) × \\(output.height), \\(output.byteCount) bytes")
            """
        case .vapor:
            return """
            import Hokusai
            import HokusaiVapor
            import Vapor

            // POST /process  --data-binary @input.jpg
            app.grouped(HokusaiErrorMiddleware()).post("process") { req async throws -> Response in
                try await req.hokusaiImage(maximumSize: 25 * 1024 * 1024)
            \(indented(8))
                    .response()
            }
            """
        case .hummingbird:
            return """
            import Hokusai
            import HokusaiHummingbird
            import Hummingbird

            // POST /process  --data-binary @input.jpg
            router.post("process") { request, _ -> Response in
                let image = try await request.hokusaiImage(maximumSize: 25 * 1024 * 1024)
                return try await image
            \(indented(8))
                    .response()
            }
            """
        }
    }
}
