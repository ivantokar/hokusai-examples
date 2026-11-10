import Foundation
import Hokusai

/// The public face of the catalog: what exists, and how a recipe becomes Hokusai calls and Swift code.
public enum Catalog {
    public static let maximumSteps = 40

    public static var operations: [OperationSpec] { allOperations.map(\.spec) }
    /// Generated sources a recipe can start from instead of an uploaded image.
    public static var sources: [OperationSpec] { RecipeSources.catalog }

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
    /// Resolves a picture name (`emblem.png`, `second`) to a pipeline. The caller owns where pictures come from.
    public typealias Assets = @Sendable (String) throws -> Hokusai

    private static let operations = Dictionary(uniqueKeysWithValues: allOperations.map { ($0.spec.id, $0) })
    private static let outputs = Dictionary(uniqueKeysWithValues: allOutputs.map { ($0.format, $0) })

    /// Validates a recipe and applies it, in order, to `source` using ordinary public Hokusai calls.
    /// Nothing is read or decoded until the caller runs a terminal on `pipeline`.
    /// A recipe with its own source (text) starts from that and ignores `source`; otherwise `source` is required.
    public static func compile(_ recipe: Recipe, source: Hokusai?, fitting maxEdge: Int? = nil, encode: Bool = true,
                               assets: Assets? = nil, sizes: [String: PixelSize] = [:]) throws -> CompiledRecipe {
        try validate(recipe)
        var pipeline: Hokusai
        if let own = recipe.source { pipeline = try RecipeSources.make(own) }
        else if let source { pipeline = source }
        else { throw RecipeError.invalidParameter(operation: "recipe", name: "source", reason: "the recipe needs an image or a generated source") }
        for step in recipe.steps where step.enabled {
            let def = operations[step.op]!
            let params = try Params(operation: step.op, specs: def.spec.params, values: step.params)
            if let contextual = def.contextApply { pipeline = try contextual(pipeline, params, StepContext(assets: assets, size: sizes[step.id])) }
            else { pipeline = try def.apply(pipeline, params) }
        }
        // A display-size copy of the *result*; the recipe itself is untouched, so it stays accurate.
        if let maxEdge { pipeline = try pipeline.resize(width: maxEdge, height: maxEdge, fit: .inside, withoutEnlargement: true) }
        // Raw output has no encoder (an encoder and raw() are exclusive), so the caller asks for the pixels only.
        guard encode else { return CompiledRecipe(pipeline: pipeline, mime: "application/octet-stream", fileExtension: "raw") }
        let out = outputs[recipe.output.format]!
        let outParams = try Params(operation: recipe.output.format, specs: out.params + metadataParams, values: recipe.output.options)
        pipeline = try out.apply(applyMetadata(pipeline, outParams), outParams)
        return CompiledRecipe(pipeline: pipeline, mime: out.mime, fileExtension: out.fileExtension)
    }

    public static func validate(_ recipe: Recipe) throws {
        guard recipe.version == Recipe.currentVersion else { throw RecipeError.unsupportedVersion(recipe.version) }
        guard recipe.steps.count <= Catalog.maximumSteps else { throw RecipeError.tooManySteps(Catalog.maximumSteps) }
        if let source = recipe.source { try RecipeSources.validate(source) }
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
    public static func chain(_ recipe: Recipe, sizes: [String: PixelSize] = [:]) throws -> [String] {
        try RecipeCompiler.validate(recipe)
        var lines: [String] = []
        for step in recipe.steps where step.enabled {
            let def = operations[step.op]!
            let params = try Params(operation: step.op, specs: def.spec.params, values: step.params)
            lines.append(def.contextSwift?(params, sizes[step.id]) ?? def.swift(params))
        }
        let out = outputs[recipe.output.format]!
        let outParams = try Params(operation: recipe.output.format, specs: out.params + metadataParams, values: recipe.output.options)
        if let policy = metadataSwift(outParams) { lines.append(policy) }
        lines.append(out.swift(outParams))
        return lines
    }

    /// Readable Swift that reproduces the final export. The source path is a placeholder: the demo's
    /// uploaded id is not a file on your machine.
    /// A step that needs the pipeline built so far as a value (a mask taken from the image's own brightness) starts its
    /// line with this marker; the generator then binds that pipeline to a name and refers to it as `§IMAGE§`.
    static let bindMarker = "\u{1}"

    /// Splits the chain at every step that needs a named pipeline. Returns the `let` bindings, the name the final
    /// expression starts from, and its remaining chained lines.
    private static func assemble(source: String, lines: [String], indent: Int) -> (bindings: String, source: String, tail: [String]) {
        let pad = String(repeating: " ", count: indent)
        var out = "", current = source, acc: [String] = [], count = 0
        for line in lines {
            if line.hasPrefix(bindMarker) {
                count += 1
                let name = count == 1 ? "image" : "image\(count)"
                out += "let \(name) = \(current)" + acc.map { "\n" + pad + $0 }.joined() + "\n"
                current = name
                acc = [String(line.dropFirst(bindMarker.count)).replacingOccurrences(of: "§IMAGE§", with: name)]
            } else { acc.append(line) }
        }
        return (out, current, acc)
    }

    /// Readable Swift that reproduces the final export. The source path is a placeholder: the demo's
    /// uploaded id is not a file on your machine.
    public static func swift(_ recipe: Recipe, target: Target = .core, sizes: [String: PixelSize] = [:]) throws -> String {
        let generated = try recipe.source.map(RecipeSources.swift)
        let lines = (generated?.chain ?? []) + (try chain(recipe, sizes: sizes))
        let ext = outputs[recipe.output.format]!.fileExtension
        func joined(_ lines: [String], _ spaces: Int) -> String { lines.map { String(repeating: " ", count: spaces) + $0 }.joined(separator: "\n") }
        let bound = lines.contains { $0.hasPrefix(bindMarker) }
        switch target {
        case .core:
            let source = generated?.expression ?? "try Hokusai(url: URL(fileURLWithPath: \"input.jpg\"))   // your source image"
            let a = assemble(source: source, lines: lines, indent: 4)
            return """
            import Foundation
            import Hokusai

            \(a.bindings)let output = try await \(bound ? a.source : (source.hasPrefix("try ") ? String(source.dropFirst(4)) : source))
            \(joined(a.tail, 4))
                .write(to: URL(fileURLWithPath: "result.\(ext)"))

            print("Wrote \\(output.width) × \\(output.height), \\(output.byteCount) bytes")
            """.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        case .vapor:
            // A generated source needs no upload: the route is a GET that builds the image from text.
            let source = generated.map { "try await " + $0.expression.dropFirst("try ".count) } ?? "try await req.hokusaiImage(maximumSize: 25 * 1024 * 1024)"
            let route = generated == nil ? "// POST /process  --data-binary @input.jpg\napp.grouped(HokusaiErrorMiddleware()).post(\"process\")" : "// GET /banner\napp.grouped(HokusaiErrorMiddleware()).get(\"banner\")"
            let a = assemble(source: source, lines: lines, indent: 8)
            let body = bound
                ? "    " + a.bindings.replacingOccurrences(of: "\n", with: "\n    ").trimmingCharacters(in: .whitespaces) + "\n    return try await \(a.source)\n\(joined(a.tail, 8))"
                : "    \(source)\n\(joined(lines, 8))"
            return """
            import Hokusai
            import HokusaiVapor
            import Vapor

            \(route) { req async throws -> Response in
            \(body)
                    .response()
            }
            """
        case .hummingbird:
            let source = generated.map { "try await " + $0.expression.dropFirst("try ".count) } ?? "upload"
            let route = generated == nil ? "// POST /process  --data-binary @input.jpg\nrouter.post(\"process\") { request, _ -> Response in" : "// GET /banner\nrouter.get(\"banner\") { _, _ -> Response in"
            let upload = generated == nil ? "    let upload = try await request.hokusaiImage(maximumSize: 25 * 1024 * 1024)\n" : ""
            let a = assemble(source: source, lines: lines, indent: 8)
            let body = bound
                ? "    " + a.bindings.replacingOccurrences(of: "\n", with: "\n    ").trimmingCharacters(in: .whitespaces) + "\n    return try await \(a.source)\n\(joined(a.tail, 8))"
                : "    return \(generated == nil ? "try await upload" : source)\n\(joined(lines, 8))"
            return """
            import Hokusai
            import HokusaiHummingbird
            import Hummingbird

            \(route)
            \(upload)\(body)
                    .response()
            }
            """
        }
    }
}
