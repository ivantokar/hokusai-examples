import Foundation
import HokusaiRecipes
import Testing
@testable import PlaygroundModel

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "fixtures")
private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appending(path: name)) }

@MainActor @Suite struct PlaygroundTests {
    private func make(_ file: String = "scene.png") async throws -> Playground {
        let p = Playground(debounce: .milliseconds(5), previewEdge: 400)
        try await p.open(data: try fixture(file), name: file)
        await p.settle()
        return p
    }

    @Test func openRendersAPreviewAndReportsTheUprightSize() async throws {
        let p = try await make("phone.jpg")
        #expect(p.sourceSize?.width == 1600 && p.sourceSize?.height == 1000)    // EXIF applied
        #expect(p.lastGood != nil)
    }

    @Test func nonImageIsRejectedWithoutReplacingTheCurrentImage() async throws {
        let p = try await make()
        await #expect(throws: (any Error).self) { try await p.open(data: Data("not an image".utf8), name: "x.txt") }
        #expect(p.sourceName == "scene.png")
    }

    @Test func previewIsReducedButExportIsTheRealRecipe() async throws {
        let p = try await make()
        p.addStep("crop")                                  // 800 × 600 at (0,0) by default
        await p.settle()
        #expect(p.lastGood?.width == 400)                  // preview fits 400
        #expect(p.lastGood?.isFullSize == false)
        let export = try await p.exportData()
        #expect(export.image.width == 800 && export.image.height == 600)
        #expect(export.image.isFullSize)
        p.showFullSize = true
        await p.settle()
        #expect(p.lastGood?.width == 800)
    }

    @Test func undoRedoRestoreTheRecipeAndTheImage() async throws {
        let p = try await make()
        p.addStep("flip")
        p.addStep("grayscale")
        #expect(p.recipe.steps.count == 2 && p.canUndo)
        p.undo(); #expect(p.recipe.steps.map(\.op) == ["flip"])
        p.undo(); #expect(p.recipe.steps.isEmpty)
        #expect(p.canRedo)
        p.redo(); p.redo(); #expect(p.recipe.steps.map(\.op) == ["flip", "grayscale"])
        #expect(!p.canRedo)
    }

    @Test func reorderingKeepsRepeatedStepsAndTheirOrder() async throws {
        let p = try await make()
        for op in ["resize", "rotate", "resize"] { p.addStep(op) }
        let ids = p.recipe.steps.map(\.id)
        p.moveStep(ids[2], by: -1)
        #expect(p.recipe.steps.map(\.op) == ["resize", "resize", "rotate"])
        p.move(from: IndexSet(integer: 0), to: 3)
        #expect(p.recipe.steps.map(\.id) == [ids[2], ids[1], ids[0]])
    }

    @Test func aSliderDragIsOneUndoEntry() async throws {
        let p = try await make()
        p.addStep("blur")
        let step = p.recipe.steps[0]
        let sigma = Catalog.operations.first { $0.id == "blur" }!.params.first { $0.name == "sigma" }!
        for v in stride(from: 4.0, through: 9.0, by: 1) { p.setParam(step: step.id, sigma, to: .number(v)) }
        #expect(p.recipe.steps[0].params["sigma"] == .number(9))
        p.undo()
        #expect(p.recipe.steps.count == 1)                 // back to "just added", not to 8
        #expect(p.recipe.steps[0].params["sigma"] == nil)
    }

    @Test func aFailedEditKeepsTheLastGoodImageAndSaysSo() async throws {
        let p = try await make()
        let good = p.lastGood
        p.addStep("crop")
        let spec = Catalog.operations.first { $0.id == "crop" }!.params.first { $0.name == "x" }!
        p.setParam(step: p.recipe.steps[0].id, spec, to: .number(1500))      // 1500 + 800 is outside a 1600 px image
        await p.settle()
        guard case .failed = p.status else { Issue.record("expected a failure, got \(p.status)"); return }
        #expect(p.lastGood?.data == good?.data)
    }

    @Test func aSupersededEvaluationNeverPublishes() async throws {
        let p = Playground(debounce: .milliseconds(1), previewEdge: 400)
        try await p.open(data: try fixture("scene.png"), name: "scene.png")
        // Many rapid edits; whatever finishes late must not overwrite the newest state.
        for i in 1...6 { p.addStep(i.isMultiple(of: 2) ? "flip" : "flop") }
        p.perform { $0.steps.removeAll() }
        p.addStep("grayscale")
        await p.settle()
        guard case .ready = p.status else { Issue.record("expected ready, got \(p.status)"); return }
        let expected = try await Playground.evaluate(data: try fixture("scene.png"), recipe: p.recipe, fitting: 400)
        #expect(p.lastGood?.data == expected.data)
    }

    @Test func generatedSwiftReproducesTheExportRecipe() async throws {
        let p = try await make()
        p.apply(preset: Presets.all[0])
        let code = p.swiftCode()
        #expect(code.contains(".resize(width: 320, height: 320, position: .attention)"))
        #expect(!code.contains("1280") && !code.contains("400"))     // preview scaling never leaks into the code
    }

    @Test func layersAndMasksNeedPicturesAndSayWhenTheyAreMissing() async throws {
        let p = try await make()
        p.addStep("layer")
        await p.settle()
        guard case .failed(let message) = p.status else { Issue.record("expected a failure without pictures, got \(p.status)"); return }
        #expect(message.contains("unknown picture"))
        p.pictures = { name in try? Data(contentsOf: fixtures.appending(path: name)) }
        await p.settle()
        guard case .ready = p.status else { Issue.record("expected ready with pictures, got \(p.status)"); return }

        // A picture mask is stretched to the size of the image entering its step, even after a resize.
        p.perform { $0.steps = [Step(op: "resize", params: ["width": .number(300), "fit": .string("inside")]), Step(op: "mask", params: ["source": .string("picture")])] }
        await p.settle()
        guard case .ready(let summary) = p.status else { Issue.record("mask: \(p.status)"); return }
        #expect(summary.width == 300)
    }

    @Test func aSecondImageIsOptionalUntilAStepAsksForIt() async throws {
        let p = try await make()
        p.pictures = { name in try? Data(contentsOf: fixtures.appending(path: name)) }
        p.perform { $0.steps = [Step(op: "layer", params: ["asset": .string("second")])] }
        await p.settle()
        guard case .failed(let message) = p.status else { Issue.record("expected a failure, got \(p.status)"); return }
        #expect(message.contains("second image"))
        p.setSecondImage(data: try fixture("emblem.png"), name: "emblem.png")
        await p.settle()
        guard case .ready = p.status else { Issue.record("expected ready, got \(p.status)"); return }
    }
}
