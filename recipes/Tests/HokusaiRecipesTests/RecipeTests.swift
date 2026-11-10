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
        let service = RenderService(uploads: store, fixtures: fixtures)
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
        let service = RenderService(uploads: store, fixtures: fixtures)
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

@Suite struct RawAndPagesTests {
    private func facts(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }

    @Test func rawOutputReportsTheLayoutItReallyUses() async throws {
        let api = DemoAPI(backend: "test")
        let id = try await api.uploads.put(try fixture("scene.png"))
        let recipe = Recipe(output: .init(format: "png"))
        for (format, channels, bits) in [("gray8", 1, 8), ("rgba8", 4, 8), ("rgb16", 3, 16), ("grayAlpha16", 2, 16)] {
            let raw = try await api.rawOutput(.init(uploadId: id, recipe: recipe, format: format, premultiplied: nil, background: nil, maxEdge: 64, page: nil))
            #expect(raw.channels == channels && raw.bitDepth == bits && raw.format == format, "\(format)")
            #expect(raw.rowStride == raw.width * channels * bits / 8)
            #expect(raw.data.count == raw.rowStride * raw.height)
            #expect(max(raw.width, raw.height) == 64)
        }
    }

    @Test func rawInputRoundTripsEveryFormatIncludingPaddedRows() async throws {
        let api = DemoAPI(backend: "test")
        for format in ["gray8", "grayAlpha8", "rgb8", "rgba8", "gray16", "grayAlpha16", "rgb16", "rgba16"] {
            let bpp = DemoAPI.rawFormats[format]!.bytesPerPixel
            for padding in [0, 8] {
                let stride = 8 * bpp + padding
                let data = Data((0..<(stride * 8 - padding)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
                let result = try await api.rawInput(.init(width: 8, height: 8, format: format, rowStride: padding == 0 ? nil : stride), data: data)
                #expect(result.roundTrip == "exact", "\(format) padding \(padding)")
                #expect(result.png.starts(with: [0x89, 0x50, 0x4e, 0x47]))
            }
        }
    }

    @Test func rawInputRefusesAWrongDeclaration() async throws {
        let api = DemoAPI(backend: "test")
        await #expect(throws: HokusaiError.self) { try await api.rawInput(.init(width: 8, height: 8, format: "rgba8"), data: Data(count: 8 * 8 * 4 - 1)) }
        await #expect(throws: HokusaiError.self) { try await api.rawInput(.init(width: 8, height: 8, format: "rgb8"), data: Data(count: 8 * 8 * 4)) }
        await #expect(throws: RecipeError.self) { try await api.rawInput(.init(width: 8, height: 8, format: "cmyk8"), data: Data(count: 256)) }
    }

    @Test func pageSelectionPicksDifferentPagesAndReportsAnimation() async throws {
        let api = DemoAPI(backend: "test")
        let pdf = try await api.uploads.put(try fixture("pages.pdf"))
        let recipe = Recipe(output: .init(format: "png"))
        let source = try facts(try await api.inspect(uploadId: pdf, recipe: nil, page: 1))["source"] as! [String: Any]
        #expect(source["pages"] as? Int == 3 && source["animated"] as? Bool == false)
        let first = try await api.render.render(RenderRequest(uploadId: pdf, recipe: recipe, page: 0))
        let third = try await api.render.render(RenderRequest(uploadId: pdf, recipe: recipe, page: 2))
        #expect(first.data != third.data)                       // each page is its own image
        #expect((first.width, first.height) == (third.width, third.height))

        let gif = try await api.uploads.put(try fixture("anim.gif"))
        let anim = try facts(try await api.inspect(uploadId: gif, recipe: nil))["source"] as! [String: Any]
        #expect(anim["animated"] as? Bool == true && anim["frames"] as? Int == 3)
        #expect(anim["frameDelaysMs"] as? [Int] == [200, 200, 200])
        #expect(anim["loopCount"] as? Int == 0)
    }
}

@Suite struct LayerAndMaskTests {
    private func alphaRange(_ png: Data) async throws -> (min: Int, max: Int, hasAlpha: Bool) {
        let image = try Hokusai(data: png)
        let meta = try await image.metadata()
        guard meta.pixel.hasAlpha else { return (255, 255, false) }
        let alpha = try await image.extractChannel(.alpha).raw(.gray8).data
        return (Int(alpha.min() ?? 0), Int(alpha.max() ?? 0), true)
    }

    @Test func anImageLayerChangesOnlyWhereItIsPlaced() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let service = RenderService(uploads: store, fixtures: fixtures)
        let plain = try await service.render(RenderRequest(uploadId: id, recipe: Recipe(steps: [], output: .init(format: "png"))))
        let layered = try await service.render(RenderRequest(uploadId: id, recipe: Recipe(steps: [Step(op: "layer", params: ["asset": .string("emblem.png"), "width": .number(200), "gravity": .string("southEast")])], output: .init(format: "png"))))
        #expect((plain.width, plain.height) == (layered.width, layered.height))
        #expect(plain.data != layered.data)
        // The top-left corner is far from the layer: its pixels are unchanged.
        let a = try await Hokusai(data: plain.data).extract(x: 0, y: 0, width: 100, height: 100).raw(.rgb8).data
        let b = try await Hokusai(data: layered.data).extract(x: 0, y: 0, width: 100, height: 100).raw(.rgb8).data
        #expect(a == b)
    }

    @Test func blendModeAndOpacityChangeTheResult() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let service = RenderService(uploads: store, fixtures: fixtures)
        func render(_ params: [String: ParamValue]) async throws -> Data {
            var p: [String: ParamValue] = ["asset": .string("phone.jpg"), "width": .number(600), "gravity": .string("northWest"), "offsetX": .number(0), "offsetY": .number(0)]
            p.merge(params) { $1 }
            return try await service.render(RenderRequest(uploadId: id, recipe: Recipe(steps: [Step(op: "layer", params: p)], output: .init(format: "png")))).data
        }
        let normal = try await render([:]), multiply = try await render(["blend": .string("multiply")]), faint = try await render(["opacity": .number(0.25)])
        #expect(normal != multiply && normal != faint && multiply != faint)
    }

    @Test func aMaskTurnsBrightnessIntoTransparency() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let service = RenderService(uploads: store, fixtures: fixtures)
        let own = try await service.render(RenderRequest(uploadId: id, recipe: Recipe(steps: [Step(op: "mask")], output: .init(format: "png"))))
        let ownAlpha = try await alphaRange(own.data)
        #expect(ownAlpha.hasAlpha && ownAlpha.min < ownAlpha.max)            // a soft mask: many alpha values

        let hard = try await service.render(RenderRequest(uploadId: id, recipe: Recipe(steps: [Step(op: "mask", params: ["threshold": .number(128)])], output: .init(format: "png"))))
        let hardAlpha = try await alphaRange(hard.data)
        #expect(hardAlpha.min == 0 && hardAlpha.max == 255)

        // A picture mask is stretched to the size of the image entering the step, even after a resize.
        let recipe = Recipe(steps: [Step(op: "resize", params: ["width": .number(500), "fit": .string("inside")]), Step(id: "m", op: "mask", params: ["source": .string("picture")])], output: .init(format: "png"))
        #expect(RecipeSizing.needsSizes(recipe))
        let pictured = try await service.render(RenderRequest(uploadId: id, recipe: recipe))
        #expect((pictured.width, pictured.height) == (500, 312))
        #expect(try await alphaRange(pictured.data).min < 255)
    }

    @Test func theMaskStepNamesTheSizeInTheGeneratedCode() async throws {
        let recipe = Recipe(steps: [Step(op: "resize", params: ["width": .number(500), "fit": .string("inside")]), Step(id: "m", op: "mask", params: ["source": .string("picture"), "feather": .number(2), "invert": .bool(true)])], output: .init(format: "png"))
        let sized = try SwiftCodeGenerator.chain(recipe, sizes: ["m": PixelSize(width: 500, height: 312)]).joined(separator: "\n")
        #expect(sized.contains(".resize(width: 500, height: 312, fit: .fill)"))
        #expect(sized.contains(".blur(sigma: 2)") && sized.contains(".negate()"))
        #expect(try SwiftCodeGenerator.chain(recipe).joined().contains("imageWidth"))     // without a size it says what is missing
    }

    @Test func aSecondImageComesFromAnUploadNeverAPath() async throws {
        let store = UploadStore()
        let base = try await store.put(try fixture("scene.png"))
        let second = try await store.put(try fixture("emblem.png"))
        let service = RenderService(uploads: store, fixtures: fixtures)
        let recipe = Recipe(steps: [Step(op: "layer", params: ["asset": .string("second"), "width": .number(150)])], output: .init(format: "png"))
        await #expect(throws: RecipeError.self) { try await service.render(RenderRequest(uploadId: base, recipe: recipe)) }     // not provided
        let ok = try await service.render(RenderRequest(uploadId: base, recipe: recipe, assets: ["second": second]))
        #expect(ok.width == 1600)
        for evil in ["../../etc/passwd", "/etc/passwd", "scene.png/../mask.png"] {
            let bad = Recipe(steps: [Step(op: "layer", params: ["asset": .string(evil)])], output: .init(format: "png"))
            await #expect(throws: RecipeError.self) { try await service.render(RenderRequest(uploadId: base, recipe: bad)) }
        }
    }

    @Test func theNewQuickOperationsDoWhatTheySay() async throws {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        let service = RenderService(uploads: store, fixtures: fixtures)
        func size(_ steps: [Step]) async throws -> (Int, Int) { let r = try await service.render(RenderRequest(uploadId: id, recipe: Recipe(steps: steps, output: .init(format: "png")))); return (r.width, r.height) }
        #expect(try await size([Step(op: "extend", params: ["top": .number(10), "bottom": .number(20), "left": .number(30), "right": .number(40)])]) == (1670, 1030))
        #expect(try await size([Step(op: "channel", params: ["channel": .string("red")])]) == (1600, 1000))
        let removed = try await service.render(RenderRequest(uploadId: id, recipe: Recipe(steps: [Step(op: "ensureAlpha"), Step(op: "removeAlpha")], output: .init(format: "png"))))
        #expect(!(try await alphaRange(removed.data).hasAlpha))
        let added = try await service.render(RenderRequest(uploadId: id, recipe: Recipe(steps: [Step(op: "ensureAlpha")], output: .init(format: "png"))))
        #expect(try await alphaRange(added.data).hasAlpha)
    }
}

@Suite struct BoundPipelineCodeTests {
    private let recipe = Recipe(steps: [Step(op: "resize", params: ["width": .number(800), "fit": .string("inside")]), Step(op: "mask", params: ["threshold": .number(100)]), Step(op: "flatten")], output: .init(format: "png"))

    @Test func aMaskFromTheImagesOwnBrightnessNamesThePipelineItIsTakenFrom() throws {
        let code = try SwiftCodeGenerator.swift(recipe)
        #expect(code.contains("let image = try Hokusai(url: URL(fileURLWithPath: \"input.jpg\"))"))
        #expect(code.contains("let output = try await image"))
        #expect(code.contains(".withAlpha(from: image.grayscale()") && code.contains(".threshold(100)"))
        #expect(!code.contains("§") && !code.contains("\u{1}"))
        // the resize belongs to the bound image, the flatten comes after the mask
        let beforeOutput = try #require(code.range(of: "let output")).lowerBound
        #expect(code[..<beforeOutput].contains(".resize(width: 800"))
        #expect(code[beforeOutput...].contains(".flatten(") || code[beforeOutput...].contains(".png()"))
    }

    @Test func serverVariantsBindToo() throws {
        let vapor = try SwiftCodeGenerator.swift(recipe, target: .vapor)
        #expect(vapor.contains("let image = try await req.hokusaiImage") && vapor.contains("return try await image"))
        let hb = try SwiftCodeGenerator.swift(recipe, target: .hummingbird)
        #expect(hb.contains("let upload = try await request.hokusaiImage") && hb.contains("let image = upload") && hb.contains("return try await image"))
    }

    @Test func twoMasksGetTwoNames() throws {
        let two = Recipe(steps: [Step(op: "mask"), Step(op: "mask", params: ["invert": .bool(true)])], output: .init(format: "png"))
        let code = try SwiftCodeGenerator.swift(two)
        #expect(code.contains("let image = ") && code.contains("let image2 = image") && code.contains("image2.grayscale()"))
    }
}

@Suite struct MatrixOperationTests {
    private func render(_ steps: [Step], format: String = "png") async throws -> RenderResult {
        let store = UploadStore()
        let id = try await store.put(try fixture("scene.png"))
        return try await RenderService(uploads: store, fixtures: fixtures).render(RenderRequest(uploadId: id, recipe: Recipe(steps: steps, output: .init(format: format))))
    }
    private func pixels(_ png: Data) async throws -> Data { try await Hokusai(data: png).raw(.rgb8).data }

    @Test func theIdentityKernelAndMatrixChangeNothingAndTheRestDo() async throws {
        let plain = try await pixels(try await render([]).data)
        #expect(try await pixels(try await render([Step(op: "convolve", params: ["kernel": .string("0 0 0 0 1 0 0 0 0")])]).data) == plain)
        #expect(try await pixels(try await render([Step(op: "recombine", params: ["matrix": .string("1 0 0 0 1 0 0 0 1")])]).data) == plain)
        #expect(try await pixels(try await render([Step(op: "convolve")]).data) != plain)       // the default is a sharpen
        #expect(try await pixels(try await render([Step(op: "recombine")]).data) != plain)      // the default is sepia
    }

    @Test func aFiveByFiveKernelNeedsTwentyFiveWeights() async throws {
        let blur = Step(op: "convolve", params: ["size": .string("5"), "kernel": .string("1 4 6 4 1 4 16 24 16 4 6 24 36 24 6 4 16 24 16 4 1 4 6 4 1"), "scale": .number(256)])
        let blurred = try await render([blur])
        #expect(try await pixels(blurred.data) != (try await pixels(try await render([]).data)))
        await #expect(throws: RecipeError.self) { _ = try await render([Step(op: "convolve", params: ["size": .string("5")])]) }
    }

    @Test func wrongShapesAndZeroScaleAreRefusedWithTheirName() async throws {
        for (step, name) in [
            (Step(op: "convolve", params: ["kernel": .string("1 2 3")]), "kernel"),
            (Step(op: "convolve", params: ["scale": .number(0)]), "scale"),
            (Step(op: "convolve", params: ["kernel": .string("1 x 3 4 5 6 7 8 9")]), "kernel"),
            (Step(op: "recombine", params: ["matrix": .string("1 0 0 1")]), "matrix"),
            (Step(op: "affine", params: ["matrix": .string("1 2 2 4")]), "matrix"),   // a·d − b·c = 0
            (Step(op: "affine", params: ["matrix": .string("1 0 0")]), "matrix"),
        ] {
            do { _ = try await render([step]); Issue.record("\(step.op) \(name) was accepted") }
            catch let RecipeError.invalidParameter(_, parameter, _) { #expect(parameter == name) }
        }
    }

    @Test func anAffineShearGrowsTheCanvasAndRotationKeepsTheWholeImage() async throws {
        let shear = try await render([Step(op: "affine", params: ["matrix": .string("1 0.4 0 1")])])
        #expect(shear.width > 1600 && shear.height == 1000)         // x′ = x + 0.4·y
        let scaled = try await render([Step(op: "affine", params: ["matrix": .string("1.5 0 0 1.5")])])
        #expect((scaled.width, scaled.height) == (2400, 1500))
        let rotated = try await render([Step(op: "affine", params: ["matrix": .string("0.9659 -0.2588 0.2588 0.9659")])])
        #expect(rotated.width > 1600 && rotated.height > 1000)
    }

    @Test func theGeneratedSwiftNamesTheLibraryCalls() throws {
        func code(_ step: Step) throws -> String { try SwiftCodeGenerator.swift(Recipe(steps: [step], output: .init(format: "png"))) }
        let sharpen = try code(Step(op: "convolve"))
        #expect(sharpen.contains(".convolve(try ConvolutionKernel(width: 3, height: 3, values: [0, -1, 0, -1, 5, -1, 0, -1, 0]))"))
        let emboss = try code(Step(op: "convolve", params: ["kernel": .string("-2 -1 0 -1 1 1 0 1 2"), "offset": .number(128)]))
        #expect(emboss.contains("offset: 128"))
        #expect(try code(Step(op: "recombine")).contains(".recombine(.sepia)"))
        #expect(try code(Step(op: "recombine", params: ["matrix": .string("1.2 0 0 0 1 0 0 0 0.8")])).contains("ColorMatrix([1.2, 0, 0, 0, 1, 0, 0, 0, 0.8])"))
        let affine = try code(Step(op: "affine", params: ["matrix": .string("1 0.4 0 1"), "interpolation": .string("bicubic"), "edges": .string("copy")]))
        #expect(affine.contains(".affine(AffineMatrix(a: 1, b: 0.4, c: 0, d: 1), edges: .copy, interpolation: .bicubic)"))
    }

    @Test func theCatalogDescribesTheGridsAndTheirPresets() throws {
        let catalog = Catalog.operations
        for (id, name) in [("convolve", "kernel"), ("recombine", "matrix"), ("affine", "matrix")] {
            let spec = try #require(catalog.first { $0.id == id }?.params.first { $0.name == name })
            #expect(spec.kind == .matrix)
            let matrix = try #require(spec.matrix)
            #expect(!matrix.presets.isEmpty)
            #expect(matrix.columns != nil || matrix.columnsFrom != nil)
            // Every preset must itself be a valid value, with the right number of numbers for its grid.
            for preset in matrix.presets {
                let count = Params.parseNumbers(preset.values)?.count
                let side = matrix.columns ?? { if case .string(let s)? = preset.params[matrix.columnsFrom ?? ""] { Int(s) } else { nil } }()
                if matrix.columnsFrom != nil { #expect(count == (side ?? 0) * (side ?? 0), "\(id): \(preset.label)") }
                else { #expect(count == (id == "recombine" ? 9 : 4), "\(id): \(preset.label)") }
            }
        }
    }

    @Test func everyPresetRendersWithoutError() async throws {
        for op in ["convolve", "recombine", "affine"] {
            let spec = try #require(Catalog.operations.first { $0.id == op }?.params.first { $0.name == (op == "convolve" ? "kernel" : "matrix") })
            for preset in try #require(spec.matrix).presets {
                var params: [String: ParamValue] = [spec.name: .string(preset.values)]
                params.merge(preset.params) { $1 }
                let result = try await render([Step(op: op, params: params)])
                #expect(result.width > 0, "\(op): \(preset.label)")
            }
        }
    }
}

@Suite struct TextSourceTests {
    private func service() -> RenderService { RenderService(uploads: UploadStore(), fixtures: fixtures) }
    private func recipe(_ params: [String: ParamValue] = [:], steps: [Step] = [], format: String = "png") -> Recipe {
        Recipe(source: RecipeSource(kind: "text", params: params), steps: steps, output: .init(format: format))
    }
    private func hasAlpha(_ data: Data) async throws -> Bool { try await Hokusai(data: data).metadata().pixel.hasAlpha }

    @Test func aTextSourceRendersWithoutAnUpload() async throws {
        let result = try await service().render(RenderRequest(recipe: recipe()))
        #expect(result.width > 200 && result.height > 100)
        #expect(result.data.prefix(4) == Data([0x89, 0x50, 0x4e, 0x47]))
    }

    @Test func sizeFollowsTheTextPaddingAndWrapping() async throws {
        func size(_ params: [String: ParamValue]) async throws -> (Int, Int) { let r = try await service().render(RenderRequest(recipe: recipe(params))); return (r.width, r.height) }
        let plain = try await size(["padding": .number(0)]), padded = try await size(["padding": .number(50)])
        #expect(padded.0 == plain.0 + 100 && padded.1 == plain.1 + 100)
        let long: [String: ParamValue] = ["content": .string("one two three four five six seven eight nine ten"), "padding": .number(0), "fontSize": .number(60)]
        var wrapped = long; wrapped["wrapWidth"] = .number(300)
        let flat = try await size(long), narrow = try await size(wrapped)
        #expect(narrow.0 <= 300 && narrow.1 > flat.1)               // wrapped to 300 px, so taller and narrower
        #expect(try await size(["content": .string("a\\nb"), "padding": .number(0)]).1 > (try await size(["content": .string("a"), "padding": .number(0)])).1)   // \n is a new line
    }

    @Test func aTransparentBackgroundKeepsAlphaAndAnOpaqueOneDoesNot() async throws {
        let clear = try await service().render(RenderRequest(recipe: recipe(["background": .string("#00000000")])))
        let solid = try await service().render(RenderRequest(recipe: recipe(["background": .string("#ffffff")])))
        #expect(try await hasAlpha(clear.data))
        #expect(!(try await hasAlpha(solid.data)))
    }

    @Test func stepsRunAfterTheSource() async throws {
        let base = try await service().render(RenderRequest(recipe: recipe()))
        let small = try await service().render(RenderRequest(recipe: recipe(steps: [Step(op: "resize", params: ["width": .number(300), "fit": .string("inside")])])))
        #expect(small.width == 300 && small.width < base.width)
    }

    @Test func aRecipeWithNeitherASourceNorAnUploadIsRefused() async throws {
        await #expect(throws: RecipeError.self) { _ = try await service().render(RenderRequest(recipe: Recipe(output: .init(format: "png")))) }
        await #expect(throws: RenderError.self) { _ = try await service().render(RenderRequest(uploadId: "gone", recipe: Recipe(output: .init(format: "png")))) }
        for bad in [RecipeSource(kind: "nope"), RecipeSource(kind: "text", params: ["content": .string("")]), RecipeSource(kind: "text", params: ["fontSize": .number(2)]), RecipeSource(kind: "text", params: ["colour": .string("red")])] {
            await #expect(throws: (any Error).self) { _ = try await service().render(RenderRequest(recipe: Recipe(source: bad, output: .init(format: "png")))) }
        }
    }

    @Test func theSourceSurvivesJSONAndAnOldRecipeStillDecodes() throws {
        let original = recipe(["content": .string("Hi")])
        let again = try JSONDecoder().decode(Recipe.self, from: try JSONEncoder().encode(original))
        #expect(again == original && again.source?.kind == "text")
        let old = try JSONDecoder().decode(Recipe.self, from: Data(#"{"version":1,"steps":[],"output":{"format":"png"}}"#.utf8))
        #expect(old.source == nil)
        let minimal = try JSONDecoder().decode(Recipe.self, from: Data(#"{"version":1,"source":{"kind":"text"},"steps":[],"output":{"format":"png"}}"#.utf8))
        #expect(minimal.source?.params.isEmpty == true)
    }

    @Test func generatedSwiftStartsFromTheTextNotAFile() throws {
        let r = recipe(["content": .string("Hi \"there\""), "wrapWidth": .number(600), "alignment": .string("left")], steps: [Step(op: "resize", params: ["width": .number(300)])])
        let core = try SwiftCodeGenerator.swift(r)
        #expect(core.contains(#"Hokusai.text("Hi \"there\"", layout: .width(600), style: TextStyle(font: "sans bold", fontSize: 120"#))
        #expect(core.contains(".extend(top: 64") && core.contains(".flatten(background:") && core.contains(".resize(width: 300"))
        #expect(!core.contains("input.jpg"))
        // Every generated line must have balanced parentheses (the snippet check compiles it, this catches it sooner).
        for line in core.split(separator: "\n") { #expect(line.filter { $0 == "(" }.count == line.filter { $0 == ")" }.count, "unbalanced: \(line)") }
        #expect(core.contains("mode: .background(.sRGB8(red: 255, green: 253, blue: 247)))\n"))
        let vapor = try SwiftCodeGenerator.swift(r, target: .vapor)
        #expect(vapor.contains(#".get("banner")"#) && vapor.contains("try await Hokusai.text(") && !vapor.contains("hokusaiImage"))
        let hb = try SwiftCodeGenerator.swift(r, target: .hummingbird)
        #expect(hb.contains(#"router.get("banner")"#) && hb.contains("try await Hokusai.text(") && !hb.contains("hokusaiImage"))
    }

    @Test func aMaskTakenFromTheTextNamesItsPipelineToo() async throws {
        let r = recipe(steps: [Step(op: "mask")])
        let code = try SwiftCodeGenerator.swift(r)
        #expect(code.contains("let image = try await Hokusai.text(") || code.contains("let image = try Hokusai.text("))
        _ = try await service().render(RenderRequest(recipe: r))
    }

    @Test func theCatalogListsTheSource() throws {
        let text = try #require(Catalog.sources.first { $0.id == "text" })
        #expect(text.params.contains { $0.name == "content" } && text.params.contains { $0.name == "background" })
    }
}
