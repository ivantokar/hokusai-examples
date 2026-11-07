import Foundation
import Hokusai

// MARK: - Spec helpers

private func num(_ name: String, _ label: String, _ def: Double, min: Double? = nil, max: Double? = nil, step: Double? = nil,
                 unit: String? = nil, advanced: Bool = false, help: String? = nil) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .number, default: .number(def), min: min, max: max, step: step, unit: unit, options: nil, advanced: advanced, help: help)
}

private func int(_ name: String, _ label: String, _ def: Int, min: Int? = nil, max: Int? = nil, unit: String? = nil,
                 advanced: Bool = false, help: String? = nil) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .integer, default: .number(Double(def)), min: min.map(Double.init), max: max.map(Double.init), step: 1, unit: unit, options: nil, advanced: advanced, help: help)
}

private func flag(_ name: String, _ label: String, _ def: Bool = false, advanced: Bool = false, help: String? = nil) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .boolean, default: .bool(def), min: nil, max: nil, step: nil, unit: nil, options: nil, advanced: advanced, help: help)
}

private func choice(_ name: String, _ label: String, _ def: String, _ options: [(String, String)], advanced: Bool = false, help: String? = nil) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .choice, default: .string(def), min: nil, max: nil, step: nil, unit: nil,
              options: options.map { Choice(value: $0.0, label: $0.1) }, advanced: advanced, help: help)
}

private func color(_ name: String, _ label: String, _ def: String, advanced: Bool = false, help: String? = nil) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .color, default: .string(def), min: nil, max: nil, step: nil, unit: nil, options: nil, advanced: advanced, help: help)
}

private func text(_ name: String, _ label: String, _ def: String, help: String? = nil) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .text, default: .string(def), min: nil, max: nil, step: nil, unit: nil, options: nil, advanced: false, help: help)
}

/// `.name(label: value, ...)`, leaving out arguments that equal the library default.
private func call(_ name: String, _ args: [(label: String, value: String, include: Bool)]) -> String {
    let parts = args.filter(\.include).map { $0.label.isEmpty ? $0.value : "\($0.label): \($0.value)" }
    return ".\(name)(\(parts.joined(separator: ", ")))"
}

private let gravities: [(String, String)] = [
    ("center", "Center"), ("north", "Top"), ("south", "Bottom"), ("east", "Right"), ("west", "Left"),
    ("northWest", "Top left"), ("northEast", "Top right"), ("southWest", "Bottom left"), ("southEast", "Bottom right"),
]

private func gravity(_ name: String) -> Gravity {
    switch name {
    case "north": .north
    case "south": .south
    case "east": .east
    case "west": .west
    case "northWest": .northWest
    case "northEast": .northEast
    case "southWest": .southWest
    case "southEast": .southEast
    default: .center
    }
}

// MARK: - Operations

struct OperationDef: Sendable {
    let spec: OperationSpec
    let apply: @Sendable (Hokusai, Params) throws -> Hokusai
    /// One chained call, for example `.resize(width: 800, fit: .cover)`.
    let swift: @Sendable (Params) -> String
}

private func op(_ id: String, _ title: String, _ group: OperationGroup, api: String, _ summary: String, params: [ParamSpec] = [],
                note: String? = nil, apply: @escaping @Sendable (Hokusai, Params) throws -> Hokusai,
                swift: @escaping @Sendable (Params) -> String) -> OperationDef {
    OperationDef(spec: OperationSpec(id: id, title: title, group: group, api: api, summary: summary, params: params, previewNote: note), apply: apply, swift: swift)
}

let allOperations: [OperationDef] = [
    // Geometry
    op("autoOrient", "Auto-orient", .geometry, api: "autoOrient()", "Applies the EXIF orientation so the pixels are upright.",
       apply: { img, _ in img.autoOrient() }, swift: { _ in ".autoOrient()" }),

    op("resize", "Resize", .geometry, api: "resize(width:height:fit:position:kernel:withoutEnlargement:withoutReduction:background:)",
       "Scales the image. Leave one side at 0 to keep the aspect ratio.",
       params: [
        int("width", "Width", 800, min: 0, max: 16_383, unit: "px", help: "0 keeps the aspect ratio from the height."),
        int("height", "Height", 0, min: 0, max: 16_383, unit: "px", help: "0 keeps the aspect ratio from the width."),
        choice("fit", "Fit", "cover", [("cover", "Cover (crop to fill)"), ("contain", "Contain (pad)"), ("inside", "Inside"), ("outside", "Outside"), ("fill", "Fill (stretch)")]),
        choice("position", "Position", "center", gravities + [("attention", "Attention (smart)"), ("entropy", "Entropy (smart)")], help: "Which part is kept when cropping."),
        choice("kernel", "Kernel", "lanczos3", ["nearest", "linear", "cubic", "mitchell", "lanczos2", "lanczos3", "mks2013", "mks2021"].map { ($0, $0) }, advanced: true),
        flag("withoutEnlargement", "Never enlarge", advanced: true),
        flag("withoutReduction", "Never reduce", advanced: true),
        color("background", "Padding colour", "#00000000", advanced: true, help: "Used by Contain."),
       ],
       note: "Exact: this is a real geometry change.",
       apply: { img, p in
        let fit: ResizeFit = switch p.string("fit") { case "contain": .contain; case "inside": .inside; case "outside": .outside; case "fill": .fill; default: .cover }
        let position: ResizePosition = switch p.string("position") {
            case "attention": .attention; case "entropy": .entropy
            default: ResizePosition(gravity: p.string("position"))
        }
        let kernel: ResizeKernel = switch p.string("kernel") {
            case "nearest": .nearest; case "linear": .linear; case "cubic": .cubic; case "mitchell": .mitchell
            case "lanczos2": .lanczos2; case "mks2013": .mks2013; case "mks2021": .mks2021; default: .lanczos3
        }
        return try img.resize(width: p.int("width") == 0 ? nil : p.int("width"), height: p.int("height") == 0 ? nil : p.int("height"),
                              fit: fit, position: position, kernel: kernel, withoutEnlargement: p.bool("withoutEnlargement"),
                              withoutReduction: p.bool("withoutReduction"), background: p.color("background"))
       },
       swift: { p in
        call("resize", [
            ("width", String(p.int("width")), p.int("width") != 0), ("height", String(p.int("height")), p.int("height") != 0),
            ("fit", "." + p.string("fit"), !p.isDefault("fit")),
            ("position", "." + p.string("position"), !p.isDefault("position")),
            ("kernel", "." + p.string("kernel"), !p.isDefault("kernel")),
            ("withoutEnlargement", "true", p.bool("withoutEnlargement")), ("withoutReduction", "true", p.bool("withoutReduction")),
            ("background", Hex.swift(p.string("background")), !p.isDefault("background")),
        ])
       }),

    op("crop", "Crop", .geometry, api: "extract(x:y:width:height:)", "Keeps a rectangle. Coordinates are in the image entering this step, after earlier steps.",
       params: [
        int("x", "Left", 0, min: 0, max: 100_000, unit: "px"), int("y", "Top", 0, min: 0, max: 100_000, unit: "px"),
        int("width", "Width", 800, min: 1, max: 16_383, unit: "px"), int("height", "Height", 600, min: 1, max: 16_383, unit: "px"),
       ],
       note: "Exact. A rectangle outside the image is reported as an error, never moved.",
       apply: { img, p in try img.extract(x: p.int("x"), y: p.int("y"), width: p.int("width"), height: p.int("height")) },
       swift: { p in ".extract(x: \(p.int("x")), y: \(p.int("y")), width: \(p.int("width")), height: \(p.int("height")))" }),

    op("smartCrop", "Smart crop", .geometry, api: "smartCrop(width:height:strategy:)", "Crops to a size around the most interesting region.",
       params: [
        int("width", "Width", 600, min: 1, max: 16_383, unit: "px"), int("height", "Height", 600, min: 1, max: 16_383, unit: "px"),
        choice("strategy", "Strategy", "attention", [("attention", "Attention"), ("entropy", "Entropy")]),
       ],
       apply: { img, p in try img.smartCrop(width: p.int("width"), height: p.int("height"), strategy: p.string("strategy") == "entropy" ? .entropy : .attention) },
       swift: { p in call("smartCrop", [("width", String(p.int("width")), true), ("height", String(p.int("height")), true), ("strategy", "." + p.string("strategy"), !p.isDefault("strategy"))]) }),

    op("rotate", "Rotate", .geometry, api: "rotate(by:background:interpolation:)", "Rotates by any angle, clockwise. Multiples of 90 are lossless.",
       params: [
        num("degrees", "Angle", 90, min: -360, max: 360, step: 1, unit: "°"),
        color("background", "Background", "#00000000", advanced: true, help: "Fills the corners of an arbitrary angle."),
        choice("interpolation", "Interpolation", "bilinear", ["nearest", "bilinear", "bicubic", "lbb", "nohalo", "vsqbs"].map { ($0, $0) }, advanced: true),
       ],
       apply: { img, p in try img.rotate(by: p.double("degrees"), background: p.color("background"), interpolation: Interpolation(rawValue: p.string("interpolation")) ?? .bilinear) },
       swift: { p in call("rotate", [("by", format(p.double("degrees")), true), ("background", Hex.swift(p.string("background")), !p.isDefault("background")), ("interpolation", "." + p.string("interpolation"), !p.isDefault("interpolation"))]) }),

    op("flip", "Flip (vertical)", .geometry, api: "flip()", "Mirrors top to bottom.", apply: { img, _ in img.flip() }, swift: { _ in ".flip()" }),
    op("flop", "Flop (horizontal)", .geometry, api: "flop()", "Mirrors left to right.", apply: { img, _ in img.flop() }, swift: { _ in ".flop()" }),

    // Effects
    op("blur", "Blur", .effects, api: "blur(sigma:precision:minAmplitude:)", "Gaussian blur.",
       params: [
        num("sigma", "Sigma", 3, min: 0.1, max: 100, step: 0.1, unit: "px"),
        choice("precision", "Precision", "integer", [("integer", "Integer"), ("float", "Float"), ("approximate", "Approximate")], advanced: true),
        num("minAmplitude", "Minimum amplitude", 0.2, min: 0.01, max: 10, step: 0.01, advanced: true),
       ],
       note: "Radius is in image pixels, so it looks stronger on a small preview.",
       apply: { img, p in try img.blur(sigma: p.double("sigma"), precision: BlurPrecision(rawValue: p.string("precision")) ?? .integer, minAmplitude: p.double("minAmplitude")) },
       swift: { p in call("blur", [("sigma", format(p.double("sigma")), true), ("precision", "." + p.string("precision"), !p.isDefault("precision")), ("minAmplitude", format(p.double("minAmplitude")), !p.isDefault("minAmplitude"))]) }),

    op("sharpen", "Sharpen", .effects, api: "sharpen(sigma:)", "Unsharp mask on luminance.",
       params: [num("sigma", "Sigma", 1.5, min: 0.1, max: 100, step: 0.1, unit: "px")],
       apply: { img, p in try img.sharpen(sigma: p.double("sigma")) },
       swift: { p in ".sharpen(sigma: \(format(p.double("sigma"))))" }),

    op("median", "Median", .effects, api: "median(size:)", "Removes speckle noise while keeping edges.",
       params: [int("size", "Window", 3, min: 1, max: 15, unit: "px")],
       apply: { img, p in try img.median(size: p.int("size")) }, swift: { p in ".median(size: \(p.int("size")))" }),

    op("threshold", "Threshold", .effects, api: "threshold(_:grayscale:)", "Turns the image into black and white at a level.",
       params: [num("level", "Level", 128, min: 0, max: 255, step: 1), flag("grayscale", "Compare luminance", true)],
       apply: { img, p in try img.threshold(p.double("level"), grayscale: p.bool("grayscale")) },
       swift: { p in call("threshold", [("", format(p.double("level")), true), ("grayscale", "false", !p.bool("grayscale"))]) }),

    // Colour
    op("grayscale", "Grayscale", .color, api: "grayscale()", "Converts to shades of gray.", apply: { img, _ in img.grayscale() }, swift: { _ in ".grayscale()" }),

    op("tint", "Tint", .color, api: "tint(_:)", "Tints the image with a colour.",
       params: [color("color", "Colour", "#e07a3a")],
       apply: { img, p in try img.tint(p.color("color")) }, swift: { p in ".tint(\(Hex.swift(p.string("color"))))" }),

    op("modulate", "Brightness, saturation, hue", .color, api: "modulate(brightness:saturation:hue:)", "Multiplies brightness and saturation and rotates hue.",
       params: [
        num("brightness", "Brightness", 1, min: 0, max: 4, step: 0.05, unit: "×"), num("saturation", "Saturation", 1, min: 0, max: 4, step: 0.05, unit: "×"),
        num("hue", "Hue", 0, min: -180, max: 180, step: 1, unit: "°"),
       ],
       apply: { img, p in try img.modulate(brightness: p.double("brightness"), saturation: p.double("saturation"), hue: p.double("hue")) },
       swift: { p in call("modulate", [("brightness", format(p.double("brightness")), !p.isDefault("brightness")), ("saturation", format(p.double("saturation")), !p.isDefault("saturation")), ("hue", format(p.double("hue")), !p.isDefault("hue"))]) }),

    op("gamma", "Gamma", .color, api: "gamma(_:)", "Applies a gamma curve.",
       params: [num("value", "Gamma", 2.2, min: 0.1, max: 10, step: 0.05)],
       apply: { img, p in try img.gamma(p.double("value")) }, swift: { p in ".gamma(\(format(p.double("value"))))" }),

    op("normalize", "Normalize", .color, api: "normalize(lower:upper:)", "Stretches contrast between two percentiles.",
       params: [num("lower", "Lower percentile", 1, min: 0, max: 99, step: 0.5, unit: "%"), num("upper", "Upper percentile", 99, min: 1, max: 100, step: 0.5, unit: "%")],
       apply: { img, p in try img.normalize(lower: p.double("lower"), upper: p.double("upper")) },
       swift: { p in call("normalize", [("lower", format(p.double("lower")), !p.isDefault("lower")), ("upper", format(p.double("upper")), !p.isDefault("upper"))]) }),

    op("clahe", "CLAHE", .color, api: "clahe(width:height:maxSlope:)", "Local contrast enhancement.",
       params: [int("width", "Tile width", 8, min: 1, max: 256, unit: "px"), int("height", "Tile height", 8, min: 1, max: 256, unit: "px"), int("maxSlope", "Max slope", 3, min: 0, max: 100)],
       apply: { img, p in try img.clahe(width: p.int("width"), height: p.int("height"), maxSlope: p.int("maxSlope")) },
       swift: { p in call("clahe", [("width", String(p.int("width")), !p.isDefault("width")), ("height", String(p.int("height")), !p.isDefault("height")), ("maxSlope", String(p.int("maxSlope")), !p.isDefault("maxSlope"))]) }),

    op("negate", "Negate", .color, api: "negate(alpha:)", "Inverts colours.", params: [flag("alpha", "Also invert alpha", advanced: true)],
       apply: { img, p in img.negate(alpha: p.bool("alpha")) }, swift: { p in p.bool("alpha") ? ".negate(alpha: true)" : ".negate()" }),

    op("flatten", "Flatten", .color, api: "flatten(background:)", "Removes transparency by blending onto a colour.",
       params: [color("background", "Background", "#ffffff")],
       apply: { img, p in try img.flatten(background: p.color("background")) }, swift: { p in call("flatten", [("background", Hex.swift(p.string("background")), !p.isDefault("background"))]) }),

    // Composition
    op("text", "Text overlay", .composition, api: "drawText(_:placement:layout:style:)", "Draws text over the image, placed by gravity.",
       params: [
        text("content", "Text", "Hokusai"),
        int("fontSize", "Size", 64, min: 6, max: 600, unit: "pt"),
        choice("font", "Font", "sans bold", [("sans", "Sans"), ("sans bold", "Sans bold"), ("serif", "Serif"), ("serif bold", "Serif bold"), ("monospace", "Monospace")]),
        color("color", "Colour", "#ffffff"),
        choice("gravity", "Position", "southEast", gravities),
        int("offsetX", "Offset X", 32, min: -10_000, max: 10_000, unit: "px", advanced: true, help: "Against an edge: padding towards the inside. On a centred axis: a signed shift."),
        int("offsetY", "Offset Y", 32, min: -10_000, max: 10_000, unit: "px", advanced: true, help: "Against an edge: padding towards the inside. On a centred axis: a signed shift."),
       ],
       note: "Text size is in image pixels at 72 dpi, so it scales with the image.",
       apply: { img, p in
        try img.drawText(.plain(p.string("content")),
                         placement: .gravity(gravity(p.string("gravity")), offsetX: p.int("offsetX"), offsetY: p.int("offsetY")),
                         style: TextStyle(font: p.string("font"), fontSize: p.int("fontSize"), color: p.color("color")))
       },
       swift: { p in
        let style = "TextStyle(font: \(swiftLiteral(p.string("font"))), fontSize: \(p.int("fontSize")), color: \(Hex.swift(p.string("color"))))"
        return ".drawText(\(swiftLiteral(p.string("content"))), placement: .gravity(.\(p.string("gravity")), offsetX: \(p.int("offsetX")), offsetY: \(p.int("offsetY"))), style: \(style))"
       }),
]

private extension ResizePosition {
    init(gravity name: String) {
        switch name {
        case "north": self = .north
        case "south": self = .south
        case "east": self = .east
        case "west": self = .west
        case "northWest": self = .northWest
        case "northEast": self = .northEast
        case "southWest": self = .southWest
        case "southEast": self = .southEast
        default: self = .center
        }
    }
}

// MARK: - Outputs

struct OutputDef: Sendable {
    let format: String
    let title: String
    let mime: String
    let fileExtension: String
    let params: [ParamSpec]
    let apply: @Sendable (Hokusai, Params) throws -> Hokusai
    let swift: @Sendable (Params) -> String
}

let allOutputs: [OutputDef] = [
    OutputDef(format: "jpeg", title: "JPEG", mime: "image/jpeg", fileExtension: "jpg",
              params: [int("quality", "Quality", 82, min: 1, max: 100), flag("progressive", "Progressive")],
              apply: { img, p in try img.jpeg(quality: p.int("quality"), progressive: p.bool("progressive")) },
              swift: { p in call("jpeg", [("quality", String(p.int("quality")), true), ("progressive", "true", p.bool("progressive"))]) }),
    OutputDef(format: "png", title: "PNG", mime: "image/png", fileExtension: "png",
              params: [int("compressionLevel", "Compression", 6, min: 0, max: 9), flag("interlaced", "Interlaced", advanced: true)],
              apply: { img, p in try img.png(compressionLevel: p.int("compressionLevel"), interlaced: p.bool("interlaced")) },
              swift: { p in call("png", [("compressionLevel", String(p.int("compressionLevel")), !p.isDefault("compressionLevel")), ("interlaced", "true", p.bool("interlaced"))]) }),
    OutputDef(format: "webp", title: "WebP", mime: "image/webp", fileExtension: "webp",
              params: [int("quality", "Quality", 82, min: 1, max: 100), int("effort", "Effort", 4, min: 0, max: 6, advanced: true), flag("lossless", "Lossless")],
              apply: { img, p in try img.webp(quality: p.int("quality"), effort: p.int("effort"), lossless: p.bool("lossless")) },
              swift: { p in call("webp", [("quality", String(p.int("quality")), true), ("effort", String(p.int("effort")), !p.isDefault("effort")), ("lossless", "true", p.bool("lossless"))]) }),
    OutputDef(format: "avif", title: "AVIF", mime: "image/avif", fileExtension: "avif",
              params: [int("quality", "Quality", 50, min: 1, max: 100), int("effort", "Effort", 4, min: 0, max: 9, advanced: true), flag("lossless", "Lossless")],
              apply: { img, p in try img.avif(quality: p.int("quality"), effort: p.int("effort"), lossless: p.bool("lossless")) },
              swift: { p in call("avif", [("quality", String(p.int("quality")), true), ("effort", String(p.int("effort")), !p.isDefault("effort")), ("lossless", "true", p.bool("lossless"))]) }),
    OutputDef(format: "tiff", title: "TIFF", mime: "image/tiff", fileExtension: "tiff",
              params: [choice("compression", "Compression", "none", [("none", "None"), ("deflate", "Deflate"), ("lzw", "LZW"), ("packBits", "PackBits")])],
              apply: { img, p in
                let c: TIFFCompression = switch p.string("compression") { case "deflate": .deflate; case "lzw": .lzw; case "packBits": .packBits; default: .none }
                return try img.tiff(compression: c)
              },
              swift: { p in call("tiff", [("compression", "." + p.string("compression"), !p.isDefault("compression"))]) }),
    OutputDef(format: "gif", title: "GIF", mime: "image/gif", fileExtension: "gif", params: [],
              apply: { img, _ in try img.gif() }, swift: { _ in ".gif()" }),
]
