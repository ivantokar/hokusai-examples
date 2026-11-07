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
        Preset(id: "noir", title: "Noir", summary: "High-contrast black and white.", sample: "phone.jpg",
               recipe: Recipe(name: "noir", steps: [
                step("autoOrient"),
                step("resize", ["width": n(900), "fit": .string("inside")]),
                step("grayscale"),
                step("clahe"),
                step("sharpen", ["sigma": n(1.2)]),
               ], output: OutputSettings(format: "jpeg", options: ["quality": n(88)]))),
        Preset(id: "watermark", title: "Text watermark", summary: "A translucent corner mark on a resized copy.", sample: "scene.png",
               recipe: Recipe(name: "watermark", steps: [
                step("resize", ["width": n(1200), "fit": .string("inside")]),
                step("text", ["content": .string("© Hokusai"), "fontSize": n(40), "color": .string("#ffffffb3")]),
               ], output: OutputSettings(format: "png"))),
    ]
}
