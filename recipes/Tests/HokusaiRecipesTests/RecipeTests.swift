import Foundation
import Hokusai
import Testing
@testable import HokusaiRecipes
@testable import HokusaiDemoServices

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "fixtures")

private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appending(path: name)) }

@Suite struct CatalogTests {
    @Test func everyOperationRendersWithDefaults() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let service = RenderService(uploads: store)
        for spec in Catalog.operations {
            // Crop is checked separately; its default rectangle is larger than a tiny test image.
            let recipe = Recipe(steps: [Step(op: spec.id)], output: .init(format: "png"))
            let result = try await service.render(RenderRequest(uploadId: id, recipe: recipe, previewMaxEdge: nil))
            #expect(result.width > 0 && result.height > 0, "\(spec.id)")
            #expect(result.data.starts(with: [0x89, 0x50, 0x4e, 0x47]), "\(spec.id) did not produce a PNG")
        }
    }

    @Test func everyOutputEncodes() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let service = RenderService(uploads: store)
        for out in Catalog.outputs {
            let recipe = Recipe(steps: [Step(op: "resize", params: ["width": .number(200), "fit": .string("inside")])], output: .init(format: out.format))
            let result = try await service.render(RenderRequest(uploadId: id, recipe: recipe, previewMaxEdge: nil))
            #expect(result.mime == out.mime)
            #expect(result.width == 200)
        }
    }

    @Test func presetsAllRender() async throws {
        let store = UploadStore()
        let service = RenderService(uploads: store)
        for preset in Presets.all {
            let id = try await store.put(try fixture(preset.sample))
            let result = try await service.render(RenderRequest(uploadId: id, recipe: preset.recipe, previewMaxEdge: nil))
            #expect(result.data.count > 100, "\(preset.id)")
        }
    }

    @Test func repeatedStepsKeepTheirOrder() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let recipe = Recipe(steps: [
            Step(op: "resize", params: ["width": .number(400), "fit": .string("inside")]),
            Step(op: "rotate", params: ["degrees": .number(90)]),
            Step(op: "resize", params: ["width": .number(100), "fit": .string("inside")]),
        ], output: .init(format: "png"))
        let result = try await RenderService(uploads: store).render(RenderRequest(uploadId: id, recipe: recipe, previewMaxEdge: nil))
        // 1600×1000 → 400×250 → rotated 250×400 → width 100 → 100×160
        #expect((result.width, result.height) == (100, 160))
        let lines = try SwiftCodeGenerator.chain(recipe)
        #expect(lines.count == 4)
        #expect(lines[0].contains("resize(width: 400"))
        #expect(lines[2].contains("resize(width: 100"))
    }

    @Test func previewDoesNotChangeTheRecipeResult() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let recipe = Recipe(steps: [Step(op: "crop", params: ["x": .number(100), "y": .number(100), "width": .number(800), "height": .number(400)])], output: .init(format: "png"))
        let service = RenderService(uploads: store)
        let full = try await service.render(RenderRequest(uploadId: id, recipe: recipe, previewMaxEdge: nil))
        let preview = try await service.render(RenderRequest(uploadId: id, recipe: recipe, previewMaxEdge: 400))
        #expect((full.width, full.height) == (800, 400))
        #expect((preview.width, preview.height) == (400, 200))
    }

    @Test func disabledStepsAreSkippedInRenderAndCode() throws {
        var step = Step(op: "grayscale")
        step.enabled = false
        let recipe = Recipe(steps: [step], output: .init(format: "png"))
        #expect(try SwiftCodeGenerator.chain(recipe) == [".png()"])
    }

    @Test func recipesSurviveJSON() throws {
        for preset in Presets.all {
            let data = try JSONEncoder().encode(preset.recipe)
            let back = try JSONDecoder().decode(Recipe.self, from: data)
            #expect(back == preset.recipe)
        }
    }
}

@Suite struct DecodingTests {
    @Test func minimalHandWrittenJSONDecodes() throws {
        let json = #"{"version":1,"steps":[{"op":"blur","params":{"sigma":2}},{"op":"flip"}],"output":{"format":"webp"}}"#
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        #expect(recipe.steps.map(\.op) == ["blur", "flip"])
        #expect(recipe.steps.allSatisfy { $0.enabled })
        #expect(recipe.output.options.isEmpty)
    }
}

@Suite struct ValidationTests {
    @Test func rejectsBadRecipes() {
        #expect(throws: RecipeError.unknownOperation("nope")) { try RecipeCompiler.validate(Recipe(steps: [Step(op: "nope")])) }
        #expect(throws: RecipeError.unknownParameter(operation: "blur", name: "radius")) { try RecipeCompiler.validate(Recipe(steps: [Step(op: "blur", params: ["radius": .number(1)])])) }
        #expect(throws: RecipeError.unsupportedVersion(9)) { try RecipeCompiler.validate(Recipe(version: 9)) }
        #expect(throws: RecipeError.unknownFormat("bmp")) { try RecipeCompiler.validate(Recipe(output: .init(format: "bmp"))) }
        #expect(throws: RecipeError.self) { try RecipeCompiler.validate(Recipe(steps: [Step(op: "blur", params: ["sigma": .number(-1)])])) }
        #expect(throws: RecipeError.self) { try RecipeCompiler.validate(Recipe(steps: [Step(op: "tint", params: ["color": .string("red")])])) }
        #expect(throws: RecipeError.self) { try RecipeCompiler.validate(Recipe(steps: Array(repeating: Step(op: "flip"), count: Catalog.maximumSteps + 1))) }
    }

    @Test func outOfBoundsCropIsAnErrorNotAMovedRectangle() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let recipe = Recipe(steps: [Step(op: "crop", params: ["x": .number(1500), "y": .number(0), "width": .number(400), "height": .number(400)])], output: .init(format: "png"))
        await #expect(throws: (any Error).self) { try await RenderService(uploads: store).render(RenderRequest(uploadId: id, recipe: recipe, previewMaxEdge: nil)) }
    }
}

@Suite struct CodeGenerationTests {
    @Test func userTextIsEscapedAsASwiftLiteral() throws {
        let hostile = "He said \"hi\" \\(secret) \n line\t2"
        let recipe = Recipe(steps: [Step(op: "text", params: ["content": .string(hostile)])], output: .init(format: "png"))
        let code = try SwiftCodeGenerator.swift(recipe)
        #expect(code.contains(#""He said \"hi\" \\(secret) \n line\t2""#))
        #expect(!code.contains("\\(secret)\""))   // the interpolation is neutralised
    }

    @Test func codeMentionsPlaceholdersNotServerPaths() throws {
        let code = try SwiftCodeGenerator.swift(Presets.all[0].recipe)
        #expect(code.contains("input.jpg"))
        #expect(code.contains(".autoOrient()"))
        #expect(code.contains(".resize(width: 320, height: 320, position: .attention)"))
        #expect(code.contains(".webp(quality: 80)"))
    }

    @Test func serverVariantsUseTheAdapters() throws {
        let recipe = Presets.all[0].recipe
        #expect(try SwiftCodeGenerator.swift(recipe, target: .vapor).contains("req.hokusaiImage"))
        #expect(try SwiftCodeGenerator.swift(recipe, target: .hummingbird).contains("request.hokusaiImage"))
    }
}

@Suite struct UploadStoreTests {
    @Test func boundsSizeCountAndLifetime() async throws {
        let store = UploadStore(limits: .init(maxUploadBytes: 10, maxTotalBytes: 25, maxEntries: 3, timeToLive: .milliseconds(150)))
        await #expect(throws: UploadStore.StoreError.tooLarge(limit: 10)) { try await store.put(Data(count: 11)) }
        await #expect(throws: UploadStore.StoreError.empty) { try await store.put(Data()) }
        var ids: [String] = []
        for _ in 0..<5 { ids.append(try await store.put(Data(count: 10))) }
        #expect(await store.count <= 2)           // 25-byte budget holds two 10-byte uploads
        #expect(await store.get(ids[0]) == nil)   // oldest evicted
        #expect(await store.get(ids[4]) != nil)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await store.get(ids[4]) == nil)   // expired
        #expect(await store.count == 0)
    }

    @Test func idsAreOpaqueTokensNotPaths() async throws {
        let store = UploadStore()
        #expect(await store.get("../../etc/passwd") == nil)
        let id = try await store.put(Data(count: 4))
        #expect(!id.contains("/") && !id.contains("."))
    }
}
