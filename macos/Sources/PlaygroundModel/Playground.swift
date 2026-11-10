import Foundation
import Hokusai
import HokusaiRecipes
import Observation

/// What the last successful evaluation produced.
public struct RenderedImage: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let mime: String
    public let milliseconds: Double
    /// `true` when this is the real result at export size rather than the reduced preview.
    public let isFullSize: Bool
}

public enum PlaygroundError: Error, CustomStringConvertible {
    case noImage
    public var description: String { "Open an image first." }
}

/// The state of one editing session. Recipe edits, selection, undo/redo and evaluation live here,
/// apart from any view, so they are testable without a window. The original file is never modified.
@MainActor @Observable
public final class Playground {
    public enum Status: Equatable {
        case idle
        case updating
        case ready(RenderedImage.Summary)
        /// The last edit failed. The previous good image stays visible and is not this edit.
        case failed(String)
    }

    // MARK: Observable state
    public var recipe = Recipe(steps: [], output: OutputSettings(format: "webp"))
    public var selection: String?
    public private(set) var sourceName: String?
    public private(set) var sourceData: Data?
    public private(set) var sourceSize: (width: Int, height: Int)?
    public private(set) var lastGood: RenderedImage?
    public private(set) var status: Status = .idle
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    /// Supplies the bundled pictures (by file name) that image layers and masks use. The app sets it.
    public var pictures: (@Sendable (String) -> Data?)? { didSet { scheduleRender() } }
    /// The visitor's second image, for layers and masks that choose “My second image”.
    public private(set) var secondImageName: String?
    private var secondImage: Data?
    public func setSecondImage(data: Data?, name: String?) { secondImage = data; secondImageName = name; bumpAndRender() }
    public var showFullSize = false { didSet { if showFullSize != oldValue { scheduleRender() } } }

    // MARK: Internals
    /// Bumps on every recipe or input change. Only the newest revision may publish a result or an error.
    public private(set) var revision = 0
    private var history: [Recipe] = []
    private var future: [Recipe] = []
    private var renderTask: Task<Void, Never>?
    private let debounce: Duration
    private let previewEdge: Int

    public init(debounce: Duration = .milliseconds(120), previewEdge: Int = 1280) {
        self.debounce = debounce
        self.previewEdge = previewEdge
    }

    // MARK: Input
    public func open(data: Data, name: String) async throws {
        let meta = try await Hokusai(data: data).metadata()        // a non-image fails here, with a clear error
        sourceData = data
        sourceName = name
        sourceSize = (meta.orientedSize.width, meta.orientedSize.height)
        lastGood = nil
        bumpAndRender()
    }

    // MARK: Editing
    public func perform(_ mutate: (inout Recipe) -> Void) {
        history.append(recipe)
        if history.count > 100 { history.removeFirst() }
        future.removeAll()
        mutate(&recipe)
        afterEdit()
    }

    public func undo() {
        guard let previous = history.popLast() else { return }
        future.append(recipe)
        recipe = previous
        afterEdit()
    }

    public func redo() {
        guard let next = future.popLast() else { return }
        history.append(recipe)
        recipe = next
        afterEdit()
    }

    public func addStep(_ op: String) {
        let step = Step(op: op)
        perform { $0.steps.append(step) }
        selection = step.id
    }

    public func removeStep(_ id: String) {
        perform { $0.steps.removeAll { $0.id == id } }
    }

    public func duplicateStep(_ id: String) {
        guard let index = recipe.steps.firstIndex(where: { $0.id == id }) else { return }
        var copy = recipe.steps[index]
        copy.id = UUID().uuidString
        perform { $0.steps.insert(copy, at: index + 1) }
        selection = copy.id
    }

    public func moveStep(_ id: String, by delta: Int) {
        guard let index = recipe.steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard recipe.steps.indices.contains(target) else { return }
        perform { $0.steps.swapAt(index, target) }
    }

    public func move(from source: IndexSet, to destination: Int) {
        perform { recipe in
            let indices = source.sorted()
            let moving = indices.map { recipe.steps[$0] }
            for index in indices.reversed() { recipe.steps.remove(at: index) }
            recipe.steps.insert(contentsOf: moving, at: destination - indices.filter { $0 < destination }.count)
        }
    }

    public func toggleStep(_ id: String) {
        perform { recipe in
            if let i = recipe.steps.firstIndex(where: { $0.id == id }) { recipe.steps[i].enabled.toggle() }
        }
    }

    /// Sets one parameter. Edits to the same parameter that follow each other closely (a slider drag)
    /// share a single undo entry.
    private var lastParamEdit: (key: String, at: ContinuousClock.Instant)?
    /// Sets several parameters of one step as a single undo entry, for controls that depend on each other
    /// (a kernel's grid and its size). A value equal to the default removes the override.
    public func setParams(step id: String, _ values: [String: ParamValue]) {
        guard let i = recipe.steps.firstIndex(where: { $0.id == id }),
              let spec = Catalog.operations.first(where: { $0.id == recipe.steps[i].op }) else { return }
        history.append(recipe); future.removeAll(); lastParamEdit = nil
        for (name, value) in values {
            guard let p = spec.params.first(where: { $0.name == name }) else { continue }
            if value != p.default { recipe.steps[i].params[name] = value } else { recipe.steps[i].params[name] = nil }
        }
        afterEdit()
    }

    public func setParam(step id: String, _ spec: ParamSpec, to value: ParamValue?) {
        let key = id + "/" + spec.name
        let now = ContinuousClock.now
        let continuing = lastParamEdit.map { $0.key == key && now - $0.at < .milliseconds(700) } ?? false
        lastParamEdit = (key, now)
        if !continuing { history.append(recipe); future.removeAll() }
        guard let i = recipe.steps.firstIndex(where: { $0.id == id }) else { return }
        if let value, value != spec.default { recipe.steps[i].params[spec.name] = value } else { recipe.steps[i].params[spec.name] = nil }
        afterEdit()
    }

    public func setOutputParam(_ spec: ParamSpec, to value: ParamValue?) {
        let key = "output/" + spec.name
        let now = ContinuousClock.now
        let continuing = lastParamEdit.map { $0.key == key && now - $0.at < .milliseconds(700) } ?? false
        lastParamEdit = (key, now)
        if !continuing { history.append(recipe); future.removeAll() }
        if let value, value != spec.default { recipe.output.options[spec.name] = value } else { recipe.output.options[spec.name] = nil }
        afterEdit()
    }

    public func setFormat(_ format: String) { perform { $0.output = OutputSettings(format: format) } }

    public func apply(preset: Preset) {
        perform { $0 = preset.recipe }
        selection = recipe.steps.first?.id
    }

    public func reset() {
        perform { $0 = Recipe(steps: [], output: OutputSettings(format: "webp")) }
        selection = nil
    }

    private func afterEdit() {
        canUndo = !history.isEmpty
        canRedo = !future.isEmpty
        if let selection, !recipe.steps.contains(where: { $0.id == selection }) { self.selection = nil }
        bumpAndRender()
    }

    // MARK: Evaluation
    private func bumpAndRender() {
        revision += 1
        scheduleRender()
    }

    private func scheduleRender() {
        renderTask?.cancel()                                   // supersede in-flight work
        guard let data = sourceData else { status = .idle; return }
        let rev = revision
        let recipe = recipe
        let pictures = pictures, second = secondImage
        let fitting = showFullSize ? nil : previewEdge
        let debounce = debounce
        status = .updating
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let outcome: Result<RenderedImage, Error>
            do { outcome = .success(try await Playground.evaluate(data: data, recipe: recipe, fitting: fitting, pictures: pictures, second: second)) }
            catch { outcome = .failure(error) }
            guard let self, !Task.isCancelled, self.revision == rev else { return }   // late native work must not publish
            switch outcome {
            case .success(let image):
                self.lastGood = image
                self.status = .ready(image.summary)
            case .failure(let error):
                if error is CancellationError { return }
                self.status = .failed(Playground.message(for: error))
            }
        }
    }

    /// Waits for the scheduled evaluation to finish (used by tests).
    public func settle() async { await renderTask?.value }

    nonisolated static func evaluate(data: Data, recipe: Recipe, fitting: Int?, pictures: (@Sendable (String) -> Data?)? = nil, second: Data? = nil) async throws -> RenderedImage {
        let started = ContinuousClock.now
        let source = try Hokusai(data: data)
        let assets: RecipeCompiler.Assets = { name in
            if name == "second" {
                guard let second else { throw RecipeError.invalidParameter(operation: "image", name: "picture", reason: "“My second image” needs a second image: choose one in the inspector") }
                return try Hokusai(data: second)
            }
            guard let data = pictures?(name) else { throw RecipeError.invalidParameter(operation: "image", name: "picture", reason: "unknown picture '\(name)'") }
            return try Hokusai(data: data)
        }
        let sizes = RecipeSizing.needsSizes(recipe) ? try await RecipeSizing.resolve(recipe, source: source, assets: assets) : [:]
        let compiled = try RecipeCompiler.compile(recipe, source: source, fitting: fitting, assets: assets, sizes: sizes)
        let output = try await compiled.pipeline.data()
        let elapsed = ContinuousClock.now - started
        return RenderedImage(data: output.data, width: output.info.width, height: output.info.height, mime: compiled.mime,
                             milliseconds: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
                             isFullSize: fitting == nil)
    }

    /// The export: the unchanged recipe on the original, never the preview.
    public func exportData() async throws -> (data: Data, fileExtension: String, image: RenderedImage) {
        guard let data = sourceData else { throw PlaygroundError.noImage }
        let image = try await Playground.evaluate(data: data, recipe: recipe, fitting: nil, pictures: pictures, second: secondImage)
        let ext = Catalog.outputs.first { $0.format == recipe.output.format }?.fileExtension ?? "bin"
        return (image.data, ext, image)
    }

    public func swiftCode(target: SwiftCodeGenerator.Target = .core) -> String {
        (try? SwiftCodeGenerator.swift(recipe, target: target)) ?? "// The recipe is not valid yet."
    }

    public nonisolated static func message(for error: Error) -> String {
        if let error = error as? RecipeError { return error.description }
        if let error = error as? HokusaiError { return error.errorDescription ?? "Image processing failed." }
        return error.localizedDescription
    }
}

extension RenderedImage {
    public struct Summary: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let bytes: Int
        public let milliseconds: Double
        public let isFullSize: Bool
    }
    public var summary: Summary { Summary(width: width, height: height, bytes: data.count, milliseconds: milliseconds, isFullSize: isFullSize) }
}
