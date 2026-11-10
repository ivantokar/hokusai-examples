import Foundation

/// Runnable starting points. Each one is an ordinary, editable recipe with a stable identifier,
/// shared by the Web UI and the macOS app.
public struct Preset: Codable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// The sample fixture that shows the recipe best.
    public let sample: String
    public let recipe: Recipe
}

public enum Presets {
    private static func step(_ op: String, _ params: [String: ParamValue] = [:]) -> Step { Step(id: "\(op)-1", op: op, params: params) }
    private static func n(_ v: Double) -> ParamValue { .number(v) }

    public static let all: [Preset] = [
        Preset(id: "thumbnail", title: "Thumbnail", summary: "Upright, square, small: the classic avatar.", sample: "phone.jpg",
               recipe: Recipe(name: "thumbnail", steps: [
                step("autoOrient"),
                step("resize", ["width": n(320), "height": n(320), "fit": .string("cover"), "position": .string("attention")]),
               ], output: OutputSettings(format: "webp", options: ["quality": n(80)]))),
        Preset(id: "smart-crop", title: "Smart crop", summary: "A 16:9 banner around what matters.", sample: "scene.png",
               recipe: Recipe(name: "smart-crop", steps: [
                step("smartCrop", ["width": n(1200), "height": n(675)]),
               ], output: OutputSettings(format: "jpeg", options: ["quality": n(85)]))),
        Preset(id: "social-card", title: "Social card", summary: "1200 × 630 with a title, ready for link previews.", sample: "scene.png",
               recipe: Recipe(name: "social-card", steps: [
                step("resize", ["width": n(1200), "height": n(630), "fit": .string("cover"), "position": .string("attention")]),
                step("modulate", ["brightness": n(0.8)]),
                step("text", ["content": .string("Hokusai"), "fontSize": n(96), "gravity": .string("southWest"), "offsetX": n(48), "offsetY": n(48)]),
               ], output: OutputSettings(format: "jpeg", options: ["quality": n(88)]))),
        Preset(id: "relief", title: "Relief", summary: "An embossed look from a convolution kernel.", sample: "scene.png",
               recipe: Recipe(name: "relief", steps: [
                step("resize", ["width": n(900), "fit": .string("inside")]),
                step("grayscale"),
                step("convolve", ["kernel": .string("-2 -1 0 -1 1 1 0 1 2"), "offset": n(128)]),
               ], output: OutputSettings(format: "png"))),
        Preset(id: "sepia", title: "Sepia print", summary: "A colour matrix warms the picture and a pale border frames it.", sample: "scene.png",
               recipe: Recipe(name: "sepia", steps: [
                step("resize", ["width": n(1000), "fit": .string("inside")]),
                step("recombine"),
                step("extend", ["top": n(24), "left": n(24), "bottom": n(24), "right": n(24), "background": .string("#f4ecd8")]),
               ], output: OutputSettings(format: "jpeg", options: ["quality": n(88)]))),
        Preset(id: "skew", title: "Skew", summary: "An affine shear on a transparent canvas.", sample: "emblem.png",
               recipe: Recipe(name: "skew", steps: [
                step("affine", ["matrix": .string("1 0.4 0 1")]),
               ], output: OutputSettings(format: "png"))),
        Preset(id: "text-card", title: "Text card", summary: "No photo: a card made from text, wrapped and padded.", sample: "scene.png",
               recipe: Recipe(name: "text-card", source: RecipeSource(kind: "text", params: [
                "content": .string("Hokusai\\nimage processing for Swift"), "fontSize": n(110), "wrapWidth": n(0), "padding": n(80),
               ]), steps: [
                step("resize", ["width": n(1200), "fit": .string("inside")]),
               ], output: OutputSettings(format: "png"))),
        Preset(id: "noir", title: "Noir", summary: "High-contrast black and white.", sample: "phone.jpg",
               recipe: Recipe(name: "noir", steps: [
                step("autoOrient"),
                step("resize", ["width": n(900), "fit": .string("inside")]),
                step("grayscale"),
                step("clahe"),
                step("sharpen", ["sigma": n(1.2)]),
               ], output: OutputSettings(format: "jpeg", options: ["quality": n(88)]))),
        Preset(id: "stamp", title: "Emblem stamp", summary: "A transparent emblem layered into a corner.", sample: "scene.png",
               recipe: Recipe(name: "stamp", steps: [
                step("resize", ["width": n(1200), "fit": .string("inside")]),
                step("layer", ["asset": .string("emblem.png"), "width": n(200), "gravity": .string("southEast"), "opacity": n(0.9)]),
               ], output: OutputSettings(format: "png"))),
        Preset(id: "fade", title: "Fade into navy", summary: "A picture mask makes the photo fade out, then the navy shows through.", sample: "scene.png",
               recipe: Recipe(name: "fade", steps: [
                step("resize", ["width": n(1000), "fit": .string("inside")]),
                step("mask", ["source": .string("picture"), "asset": .string("mask.png")]),
                step("flatten", ["background": .string("#1b3a57")]),
               ], output: OutputSettings(format: "jpeg", options: ["quality": n(88)]))),
        Preset(id: "cutout", title: "Brightness cut-out", summary: "Keeps only the bright parts of the picture: its own brightness becomes its transparency.", sample: "scene.png",
               recipe: Recipe(name: "cutout", steps: [
                step("resize", ["width": n(1000), "fit": .string("inside")]),
                step("mask", ["threshold": n(110), "feather": n(1.5)]),
               ], output: OutputSettings(format: "png"))),
        Preset(id: "watermark", title: "Text watermark", summary: "A translucent corner mark on a resized copy.", sample: "scene.png",
               recipe: Recipe(name: "watermark", steps: [
                step("resize", ["width": n(1200), "fit": .string("inside")]),
                step("text", ["content": .string("© Hokusai"), "fontSize": n(40), "color": .string("#ffffffb3")]),
               ], output: OutputSettings(format: "png"))),
    ]
}
