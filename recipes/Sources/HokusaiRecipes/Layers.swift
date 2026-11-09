import Foundation
import Hokusai

/// The pictures an image layer or a mask can use. `second` is the visitor's second image.
public let layerAssetChoices: [(String, String)] = [
    ("emblem.png", "Emblem (transparent)"), ("scene.png", "Scene"), ("phone.jpg", "Phone photo"), ("mask.png", "Gradient mask (greyscale)"), ("second", "My second image"),
]

public struct PixelSize: Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// What a step may need from outside the pipeline.
struct StepContext: Sendable {
    let assets: RecipeCompiler.Assets?
    /// The size of the image entering the step, for operations whose second picture must match it.
    let size: PixelSize?

    func asset(_ name: String) throws -> Hokusai {
        guard let assets else { throw RecipeError.invalidParameter(operation: "image", name: "picture", reason: "this runtime has no pictures to place; open the recipe where pictures are available") }
        return try assets(name)
    }
}

/// A mask must come out the same size as the image it applies to, but a pipeline only knows its size when it runs.
/// So the size entering each such step is measured once, by evaluating the steps before it.
public enum RecipeSizing {
    public static func needsSizes(_ recipe: Recipe) -> Bool {
        recipe.steps.contains { $0.enabled && $0.op == "mask" && (try? Params(operation: "mask", specs: maskSpecs, values: $0.props))?.string("source") == "picture" }
    }
    private static var maskSpecs: [ParamSpec] { Catalog.operations.first { $0.id == "mask" }!.params }

    public static func resolve(_ recipe: Recipe, source: Hokusai, assets: RecipeCompiler.Assets?) async throws -> [String: PixelSize] {
        var sizes: [String: PixelSize] = [:]
        for (index, step) in recipe.steps.enumerated() where step.enabled && step.op == "mask" {
            let params = try Params(operation: "mask", specs: maskSpecs, values: step.params)
            guard params.string("source") == "picture" else { continue }
            var prefix = recipe
            prefix.steps = Array(recipe.steps[..<index])
            let pipeline = try RecipeCompiler.compile(prefix, source: source, encode: false, assets: assets, sizes: sizes).pipeline
            let raw = try await pipeline.raw(.gray8)
            sizes[step.id] = PixelSize(width: raw.width, height: raw.height)
        }
        return sizes
    }
}

private extension Step {
    var props: [String: ParamValue] { params }
}

private let blends: [(String, String, BlendMode)] = [
    ("over", "Over (normal)", .over), ("multiply", "Multiply", .multiply), ("screen", "Screen", .screen), ("overlay", "Overlay", .overlay),
    ("darken", "Darken", .darken), ("lighten", "Lighten", .lighten), ("colorDodge", "Colour dodge", .colorDodge), ("colorBurn", "Colour burn", .colorBurn),
    ("hardLight", "Hard light", .hardLight), ("softLight", "Soft light", .softLight), ("difference", "Difference", .difference), ("exclusion", "Exclusion", .exclusion),
    ("add", "Add", .add), ("atop", "Atop", .atop), ("in", "In (keep the base inside the layer)", .in), ("out", "Out (cut the layer away)", .out), ("xor", "Xor", .xor),
    ("destinationIn", "Destination in", .destinationIn), ("destinationOut", "Destination out", .destinationOut), ("destinationOver", "Destination over (layer behind)", .destinationOver),
]

private func blendSwift(_ name: String) -> String { name == "in" ? ".`in`" : "." + name }

private func assetSwift(_ name: String) -> String {
    // A placeholder file name: the visitor's second image is not a file on your machine.
    swiftLiteral(name == "second" ? "layer.png" : name)
}

let layerOperations: [OperationDef] = [
    OperationDef(
        spec: OperationSpec(id: "layer", title: "Image layer", group: .composition, api: "composite(_:space:)",
            summary: "Places another picture over the image, with a blend mode, opacity and placement. The layer is its own pipeline, resized here.",
            params: [
                choice("asset", "Picture", "emblem.png", layerAssetChoices),
                int("width", "Layer width", 240, min: 0, max: 16_383, unit: "px", help: "Scales the layer to this width. 0 keeps its natural size."),
                choice("gravity", "Position", "southEast", gravities),
                int("offsetX", "Offset X", 32, min: -10_000, max: 10_000, unit: "px", advanced: true, help: "Against an edge: padding towards the inside. On a centred axis: a signed shift."),
                int("offsetY", "Offset Y", 32, min: -10_000, max: 10_000, unit: "px", advanced: true),
                flag("tile", "Tile across the whole image", false, advanced: true),
                choice("blend", "Blend mode", "over", blends.map { ($0.0, $0.1) }),
                num("opacity", "Opacity", 1, min: 0, max: 1, step: 0.05),
                choice("space", "Blend in", "srgb", [("srgb", "sRGB (as design tools do)"), ("linear", "Linear light")], advanced: true),
            ],
            previewNote: "A pixel size such as the layer width is in image pixels, so it looks relatively larger on a reduced preview."),
        apply: { img, _ in img },
        contextApply: { img, p, context in
            var layer = try context.asset(p.string("asset"))
            if p.int("width") > 0 { layer = try layer.resize(width: p.int("width"), fit: .inside) }
            let placement: Placement = p.bool("tile") ? .tile(gravity: gravity(p.string("gravity"))) : .gravity(gravity(p.string("gravity")), offsetX: p.int("offsetX"), offsetY: p.int("offsetY"))
            let blend = blends.first { $0.0 == p.string("blend") }?.2 ?? .over
            return try img.composite([CompositeLayer(layer, placement: placement, blend: blend, opacity: p.double("opacity"))], space: p.string("space") == "linear" ? .linear : .srgb)
        },
        swift: { p in
            let layer = "try Hokusai(url: URL(fileURLWithPath: \(assetSwift(p.string("asset")))))" + (p.int("width") > 0 ? ".resize(width: \(p.int("width")), fit: .inside)" : "")
            let placement = p.bool("tile") ? ".tile(gravity: .\(p.string("gravity")))" : ".gravity(.\(p.string("gravity")), offsetX: \(p.int("offsetX")), offsetY: \(p.int("offsetY")))"
            var args = ["placement: \(placement)"]
            if p.string("blend") != "over" { args.append("blend: \(blendSwift(p.string("blend")))") }
            if p.double("opacity") != 1 { args.append("opacity: \(format(p.double("opacity")))") }
            let space = p.string("space") == "linear" ? ", space: .linear" : ""
            return ".composite([CompositeLayer(\(layer), \(args.joined(separator: ", ")))]\(space))"
        }),

    OperationDef(
        spec: OperationSpec(id: "mask", title: "Alpha from a mask", group: .composition, api: "withAlpha(from:)",
            summary: "Uses a mask's brightness as the image's transparency: white keeps a pixel, black hides it. The mask is either this image's own brightness or a picture stretched to the image's size.",
            params: [
                choice("source", "Mask", "luminance", [("luminance", "This image's own brightness"), ("picture", "A picture")]),
                choice("asset", "Mask picture", "mask.png", layerAssetChoices, help: "Used when the mask is a picture. It is stretched to the size of the image entering this step."),
                int("threshold", "Make it hard-edged at", 0, min: 0, max: 255, help: "0 keeps the soft mask. Above 0, pixels at or over this brightness are kept and the rest hidden."),
                num("feather", "Soften the edge", 0, min: 0, max: 50, step: 0.5, unit: "px", help: "A blur applied to the mask, in image pixels."),
                flag("invert", "Invert the mask"),
            ],
            previewNote: "Needs the size of the image entering this step, which is measured by running the steps before it."),
        apply: { img, _ in img },
        contextApply: { img, p, context in
            var mask: Hokusai
            if p.string("source") == "picture" {
                guard let size = context.size else { throw RecipeError.invalidParameter(operation: "mask", name: "picture", reason: "the size of the image entering this step was not measured") }
                mask = try context.asset(p.string("asset")).resize(width: size.width, height: size.height, fit: .fill).grayscale()
            } else {
                mask = img.grayscale()
            }
            if p.double("feather") > 0 { mask = try mask.blur(sigma: p.double("feather")) }
            if p.int("threshold") > 0 { mask = try mask.threshold(Double(p.int("threshold"))) }
            if p.bool("invert") { mask = mask.negate() }
            return img.withAlpha(from: mask)
        },
        contextSwift: { p, size in
            var mask: String
            if p.string("source") == "picture" {
                let w = size.map { String($0.width) } ?? "imageWidth", h = size.map { String($0.height) } ?? "imageHeight"
                mask = "try Hokusai(url: URL(fileURLWithPath: \(assetSwift(p.string("asset")))))\n        .resize(width: \(w), height: \(h), fit: .fill)   // the size of the image entering this step\n        .grayscale()"
            } else {
                mask = "§IMAGE§.grayscale()"                     // the pipeline built so far, bound to a name by the generator
            }
            if p.double("feather") > 0 { mask += "\n        .blur(sigma: \(format(p.double("feather"))))" }
            if p.int("threshold") > 0 { mask += "\n        .threshold(\(p.int("threshold")))" }
            if p.bool("invert") { mask += "\n        .negate()" }
            return (p.string("source") == "picture" ? "" : SwiftCodeGenerator.bindMarker) + ".withAlpha(from: \(mask))"
        },
        swift: { _ in ".withAlpha(from: mask)" }),

    op("extend", "Extend canvas", .geometry, api: "extend(top:left:bottom:right:mode:)", "Adds space around the image, filled with a colour or by repeating its edges.",
       params: [int("top", "Top", 40, min: 0, max: 10_000, unit: "px"), int("left", "Left", 40, min: 0, max: 10_000, unit: "px"), int("bottom", "Bottom", 40, min: 0, max: 10_000, unit: "px"), int("right", "Right", 40, min: 0, max: 10_000, unit: "px"),
                choice("mode", "Fill with", "colour", [("colour", "A colour"), ("copy", "The nearest edge pixel"), ("repeat", "A tiled copy"), ("mirror", "A mirrored tiling")]),
                color("background", "Colour", "#ffffff")],
       apply: { img, p in
        let mode: ExtendMode = switch p.string("mode") { case "copy": .copy; case "repeat": .repeat; case "mirror": .mirror; default: .background(p.color("background")) }
        return try img.extend(top: p.int("top"), left: p.int("left"), bottom: p.int("bottom"), right: p.int("right"), mode: mode)
       },
       swift: { p in
        let mode = p.string("mode") == "colour" ? ".background(\(Hex.swift(p.string("background"))))" : "." + (p.string("mode") == "repeat" ? "`repeat`" : p.string("mode"))
        return ".extend(top: \(p.int("top")), left: \(p.int("left")), bottom: \(p.int("bottom")), right: \(p.int("right")), mode: \(mode))"
       }),
    op("trim", "Trim borders", .geometry, api: "trim(threshold:)", "Cuts away a uniform border, judged from the top-left pixel.",
       params: [num("threshold", "Tolerance", 10, min: 0, max: 255, step: 1)],
       apply: { img, p in try img.trim(threshold: p.double("threshold")) }, swift: { p in call("trim", [("threshold", format(p.double("threshold")), !p.isDefault("threshold"))]) }),
    op("linear", "Linear (multiply and add)", .color, api: "linear(multiply:add:)", "Multiplies every value and adds an offset, the way contrast and brightness controls often work.",
       params: [num("multiply", "Multiply", 1.2, min: 0, max: 10, step: 0.05, unit: "×"), num("add", "Add", 0, min: -255, max: 255, step: 1)],
       apply: { img, p in try img.linear(multiply: p.double("multiply"), add: p.double("add")) },
       swift: { p in call("linear", [("multiply", format(p.double("multiply")), !p.isDefault("multiply")), ("add", format(p.double("add")), !p.isDefault("add"))]) }),
    op("colorspace", "Colour space", .color, api: "convert(to:)", "Converts to sRGB or to greyscale. This changes the pixels, unlike merely embedding a colour profile.",
       params: [choice("space", "Convert to", "grayscale", [("sRGB", "sRGB"), ("grayscale", "Greyscale")])],
       apply: { img, p in try img.convert(to: p.string("space") == "sRGB" ? .sRGB : .grayscale) }, swift: { p in ".convert(to: .\(p.string("space")))" }),
    op("ensureAlpha", "Ensure alpha", .color, api: "ensureAlpha(opacity:)", "Adds an opaque alpha channel if there is none. Different from flattening: nothing is blended.",
       params: [num("opacity", "Opacity of the new channel", 1, min: 0, max: 1, step: 0.05)],
       apply: { img, p in try img.ensureAlpha(opacity: p.double("opacity")) }, swift: { p in call("ensureAlpha", [("opacity", format(p.double("opacity")), !p.isDefault("opacity"))]) }),
    op("removeAlpha", "Remove alpha", .color, api: "removeAlpha()", "Drops the alpha channel without blending. Transparent pixels show whatever colour they stored.",
       apply: { img, _ in img.removeAlpha() }, swift: { _ in ".removeAlpha()" }),
    op("dilate", "Dilate", .effects, api: "dilate(radius:)", "Grows bright areas.", params: [int("radius", "Radius", 2, min: 1, max: 50, unit: "px")],
       apply: { img, p in try img.dilate(radius: p.int("radius")) }, swift: { p in ".dilate(radius: \(p.int("radius")))" }),
    op("erode", "Erode", .effects, api: "erode(radius:)", "Shrinks bright areas.", params: [int("radius", "Radius", 2, min: 1, max: 50, unit: "px")],
       apply: { img, p in try img.erode(radius: p.int("radius")) }, swift: { p in ".erode(radius: \(p.int("radius")))" }),
    op("edges", "Edge detection", .effects, api: "edges(_:)", "Bright where neighbouring pixels differ a lot: an image-processing step, not object detection.",
       params: [choice("detector", "Detector", "sobel", [("sobel", "Sobel"), ("scharr", "Scharr"), ("prewitt", "Prewitt"), ("canny", "Canny")]), num("sigma", "Canny smoothing", 1.4, min: 0.1, max: 20, step: 0.1, unit: "px", advanced: true)],
       apply: { img, p in
        let d: EdgeDetector = switch p.string("detector") { case "scharr": .scharr; case "prewitt": .prewitt; case "canny": .canny(sigma: p.double("sigma")); default: .sobel }
        return try img.edges(d)
       },
       swift: { p in p.string("detector") == "canny" ? ".edges(.canny(sigma: \(format(p.double("sigma")))))" : p.string("detector") == "sobel" ? ".edges()" : ".edges(.\(p.string("detector")))" }),
    op("channel", "Extract a channel", .color, api: "extractChannel(_:)", "Keeps one channel as a greyscale image. Alpha needs an image that has one.",
       params: [choice("channel", "Channel", "luminance", [("red", "Red"), ("green", "Green"), ("blue", "Blue"), ("alpha", "Alpha"), ("luminance", "Luminance")])],
       apply: { img, p in
        let c: Channel = switch p.string("channel") { case "red": .red; case "green": .green; case "blue": .blue; case "alpha": .alpha; default: .luminance }
        return img.extractChannel(c)
       },
       swift: { p in ".extractChannel(.\(p.string("channel")))" }),
]

let allOperations: [OperationDef] = coreOperations + layerOperations
