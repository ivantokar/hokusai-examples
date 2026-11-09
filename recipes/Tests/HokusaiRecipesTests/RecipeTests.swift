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

@Suite struct InspectTests {
    private func facts(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }

    @Test func metadataRetentionIsVerifiedOnTheExportedBytes() async throws {
        let api = DemoAPI(backend: "test")
        let id = try await api.uploads.put(try fixture("metadata.jpg"))
        func exported(_ options: [String: ParamValue]) async throws -> [String: Any] {
            let recipe = Recipe(steps: [], output: .init(format: "jpeg", options: options))
            return try facts(try await api.inspect(uploadId: id, recipe: recipe))["output"] as! [String: Any]
        }
        let source = try facts(try await api.inspect(uploadId: id, recipe: nil))["source"] as! [String: Any]
        #expect((source["exifBytes"] as! Int) > 0 && (source["iccBytes"] as! Int) > 0 && (source["xmpBytes"] as! Int) > 0 && (source["iptcBytes"] as! Int) > 0)

        // The default keeps ICC, orientation and density and drops the rest. Orientation and density are stored
        // inside an EXIF block, so a small one remains: the camera details are gone, not the block itself.
        let byDefault = try await exported([:])
        #expect(byDefault["xmpBytes"] as! Int == 0 && byDefault["iptcBytes"] as! Int == 0)
        #expect((byDefault["exifBytes"] as! Int) < (source["exifBytes"] as! Int))
        #expect((byDefault["iccBytes"] as! Int) > 0)

        let stripped = try await exported(["keepOrientation": .bool(false), "keepDensity": .bool(false)])
        #expect(stripped["exifBytes"] as! Int == 0)

        let all = try await exported(["keepExif": .bool(true), "keepXmp": .bool(true), "keepIptc": .bool(true)])
        #expect((all["exifBytes"] as! Int) > 0 && (all["xmpBytes"] as! Int) > 0 && (all["iptcBytes"] as! Int) > 0)

        let noIcc = try await exported(["keepIcc": .bool(false)])
        #expect(noIcc["iccBytes"] as! Int == 0)
    }

    @Test func policyIsPrintedOnlyWhenItDiffersFromTheDefault() throws {
        #expect(try !SwiftCodeGenerator.chain(Recipe(output: .init(format: "jpeg"))).joined().contains("metadataPolicy"))
        let recipe = Recipe(output: .init(format: "jpeg", options: ["keepExif": .bool(true), "keepIcc": .bool(false)]))
        let line = try SwiftCodeGenerator.chain(recipe)[0]
        #expect(line == ".metadataPolicy(MetadataPolicy(exif: .preserve, icc: .remove))")
    }

    @Test func stopBeforeShowsTheImageEnteringAStep() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let crop = Step(id: "c", op: "crop", params: ["width": .number(100), "height": .number(100)])
        let recipe = Recipe(steps: [Step(op: "resize", params: ["width": .number(400), "fit": .string("inside")]), Step(op: "rotate", params: ["degrees": .number(90)]), crop], output: .init(format: "png"))
        let service = RenderService(uploads: store)
        let entering = try await service.render(RenderRequest(uploadId: id, recipe: recipe, stopBefore: "c"))
        #expect((entering.width, entering.height) == (250, 400))     // 1600×1000 → 400×250 → rotated
        let result = try await service.render(RenderRequest(uploadId: id, recipe: recipe))
        #expect((result.width, result.height) == (100, 100))
        await #expect(throws: RenderError.self) { try await service.render(RenderRequest(uploadId: id, recipe: recipe, stopBefore: "nope")) }
    }
}

#if canImport(PDFKit)
import PDFKit
#endif

@Suite struct VectorDocumentTests {
    private func assets(upload: Data? = nil) -> VectorCompiler.Assets {
        { name in
            if name == "upload" { guard let upload else { throw VectorError.noUpload }; return try Hokusai(data: upload) }
            return try Hokusai(data: try fixture(name))
        }
    }

    @Test func reportRendersATwoPagePDFWithRealText() async throws {
        let document = try VectorCompiler.compile(VectorPresets.report, assets: assets())
        let output = try await document.data()
        #expect(output.data.starts(with: Array("%PDF".utf8)))
        #expect(output.info.pageCount == 2)
        // Cairo writes a character map for every text font; a PDF of only pixels has none.
        #expect(output.data.range(of: Data("/ToUnicode".utf8)) != nil)
        #if canImport(PDFKit)
        // The strongest check: a PDF reader can extract the words, so they are selectable text and not pixels.
        let reader = try #require(PDFDocument(data: output.data))
        #expect(reader.pageCount == 2)
        let text = reader.string ?? ""
        #expect(text.range(of: "Lighthouse report") != nil, "Lighthouse report is not selectable text")
        #expect(text.range(of: "Findings") != nil, "Findings is not selectable text")
        #expect(text.range(of: "ten seconds") != nil, "ten seconds is not selectable text")
        #endif
    }

    @Test func aRasterPDFHasNoSelectableText() async throws {
        let recipe = Recipe(steps: [Step(op: "text", params: ["content": .string("Pixels only")])], output: .init(format: "pdf"))
        let compiled = try RecipeCompiler.compile(recipe, source: try Hokusai(data: try fixture("scene.png")))
        let output = try await compiled.pipeline.data()
        #expect(output.info.pdf?.pageCount == 1)
        #expect(output.data.range(of: Data("/ToUnicode".utf8)) == nil)
        #if canImport(PDFKit)
        #expect((PDFDocument(data: output.data)?.string ?? "").range(of: "Pixels only") == nil)
        #endif
    }

    @Test func invalidDocumentsAreReportedNotMoved() throws {
        #expect(throws: VectorError.noPages) { try VectorCompiler.validate(VectorDocumentSpec(pages: [])) }
        #expect(throws: VectorError.unknownItem("table")) { try VectorCompiler.validate(VectorDocumentSpec(pages: [VectorPageSpec(items: [VectorItem(type: "table")])])) }
        #expect(throws: (any Error).self) {   // a rectangle with neither fill nor outline
            _ = try VectorCompiler.compile(VectorDocumentSpec(pages: [VectorPageSpec(items: [VectorItem(type: "rect", props: ["fill": .string("#00000000")])])]), assets: assets())
        }
        #expect(throws: VectorError.noUpload) {
            _ = try VectorCompiler.compile(VectorDocumentSpec(pages: [VectorPageSpec(items: [VectorItem(type: "image", props: ["asset": .string("upload")])])]), assets: assets())
        }
    }

    @Test func generatedSwiftMentionsEveryItemAndEscapesText() throws {
        var doc = VectorPresets.report
        doc.pages[0].items.append(VectorItem(type: "text", props: ["content": .string("He said \"hi\" \\(x)")]))
        let code = try VectorCodeGenerator.swift(doc)
        #expect(code.contains("VectorPage(size: .a4())"))
        #expect(code.contains(".linearGradient(from: .sRGB8(red: 27, green: 58, blue: 87), to:"))
        #expect(code.contains(".markup(") && code.contains(".image(try Hokusai(url:"))
        #expect(code.contains(#"He said \"hi\" \\(x)"#))
        #expect(code.contains("VectorDocument(pages: [page1, page2], metadata: PDFDocumentMetadata(title: \"Lighthouse report\", author: \"Hokusai examples\"))"))
    }

    @Test func documentsSurviveJSON() throws {
        let back = try JSONDecoder().decode(VectorDocumentSpec.self, from: try JSONEncoder().encode(VectorPresets.report))
        #expect(back == VectorPresets.report)
    }

    @Test func rasterPDFOptionsAreHonoured() async throws {
        let recipe = Recipe(output: .init(format: "pdf", options: ["pageSize": .string("letter"), "orientation": .string("landscape"), "margins": .number(18), "title": .string("T")]))
        let output = try await RecipeCompiler.compile(recipe, source: try Hokusai(data: try fixture("scene.png"))).pipeline.data()
        #expect(output.info.pdf?.pageWidth == 792 && output.info.pdf?.pageHeight == 612)
        let code = try SwiftCodeGenerator.chain(recipe).last!
        #expect(code.contains(".letter(.landscape)") && code.contains("margins: .all(18)") && code.contains("PDFDocumentMetadata(title: \"T\")"))
    }
}
