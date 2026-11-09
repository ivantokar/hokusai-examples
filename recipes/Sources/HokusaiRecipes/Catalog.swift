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

/// Which embedded blocks the encoded file keeps. These follow `MetadataPolicy`, whose defaults keep the
/// colour profile, orientation and density and drop everything else.
let metadataParams: [ParamSpec] = [
    flag("keepExif", "Keep EXIF", false, help: "Camera, lens and capture details."),
    flag("keepIcc", "Keep colour profile (ICC)", true, help: "An embedded profile is different from a colour conversion."),
    flag("keepXmp", "Keep XMP", false),
    flag("keepIptc", "Keep IPTC", false),
    flag("keepOther", "Keep other blocks", false, advanced: true),
    flag("keepOrientation", "Keep orientation tag", true, advanced: true, help: "Removing it without Auto-orient first leaves the pixels sideways."),
    flag("keepDensity", "Keep density (dpi)", true, advanced: true),
]

/// The metadata policy as Hokusai spells it, and as the code generator prints it.
func applyMetadata(_ img: Hokusai, _ p: Params) -> Hokusai {
    func action(_ name: String) -> MetadataPolicy.Action { p.bool(name) ? .preserve : .remove }
    return img.metadataPolicy(MetadataPolicy(exif: action("keepExif"), icc: action("keepIcc"), xmp: action("keepXmp"), iptc: action("keepIptc"),
                                             other: action("keepOther"), orientation: action("keepOrientation"), density: action("keepDensity")))
}

func metadataSwift(_ p: Params) -> String? {
    let all: [(String, String)] = [("exif", "keepExif"), ("icc", "keepIcc"), ("xmp", "keepXmp"), ("iptc", "keepIptc"),
                                   ("other", "keepOther"), ("orientation", "keepOrientation"), ("density", "keepDensity")]
    let changed = all.filter { !p.isDefault($0.1) }
    guard !changed.isEmpty else { return nil }
    return ".metadataPolicy(MetadataPolicy(\(changed.map { "\($0.0): \(p.bool($0.1) ? ".preserve" : ".remove")" }.joined(separator: ", "))))"
}

private func opts(_ name: String, _ args: [(label: String, value: String, include: Bool)]) -> String {
    let parts = args.filter(\.include).map { "\($0.label): \($0.value)" }
    let type = ["jpeg": "JPEGOptions", "webp": "WebPOptions", "avif": "AVIFOptions", "heif": "HEIFOptions"][name] ?? name
    return ".\(name)(options: \(type)(\(parts.joined(separator: ", "))))"
}

private let chromaChoices: [(String, String)] = [("automatic", "Automatic"), ("yuv420", "4:2:0"), ("yuv444", "4:4:4")]
private func chroma(_ s: String) -> ChromaSubsampling { s == "yuv420" ? .yuv420 : s == "yuv444" ? .yuv444 : .automatic }
private func depth(_ n: Int) -> HEIFBitDepth { n == 12 ? .twelve : n == 10 ? .ten : .eight }

private func pdfPageSize(_ p: Params) -> PDFPageSize {
    let orientation: PDFPageOrientation = p.string("orientation") == "landscape" ? .landscape : .portrait
    switch p.string("pageSize") {
    case "a4": return .a4(orientation)
    case "letter": return .letter(orientation)
    case "custom": return .points(width: p.double("pageWidth"), height: p.double("pageHeight"))
    default: return .image(dpi: p.double("imageDpi"))
    }
}

let allOutputs: [OutputDef] = [
    OutputDef(format: "jpeg", title: "JPEG", mime: "image/jpeg", fileExtension: "jpg",
              params: [int("quality", "Quality", 82, min: 1, max: 100), flag("progressive", "Progressive"),
                       choice("chroma", "Chroma subsampling", "automatic", chromaChoices, advanced: true, help: "4:4:4 keeps colour detail at a larger size."),
                       flag("optimizeCoding", "Optimise Huffman tables", advanced: true, help: "Slightly smaller, slower.")],
              apply: { img, p in try img.jpeg(options: JPEGOptions(quality: p.int("quality"), progressive: p.bool("progressive"), chromaSubsampling: chroma(p.string("chroma")), optimizeCoding: p.bool("optimizeCoding"))) },
              swift: { p in
                if p.isDefault("chroma") && p.isDefault("optimizeCoding") { return call("jpeg", [("quality", String(p.int("quality")), true), ("progressive", "true", p.bool("progressive"))]) }
                return opts("jpeg", [("quality", String(p.int("quality")), true), ("progressive", "true", p.bool("progressive")), ("chromaSubsampling", "." + p.string("chroma"), !p.isDefault("chroma")), ("optimizeCoding", "true", p.bool("optimizeCoding"))])
              }),
    OutputDef(format: "png", title: "PNG", mime: "image/png", fileExtension: "png",
              params: [int("compressionLevel", "Compression", 6, min: 0, max: 9), flag("interlaced", "Interlaced", advanced: true),
                       flag("palette", "Quantise to a palette", advanced: true, help: "Smaller files, at most 256 colours. Needs libimagequant, reported by the capabilities."),
                       int("paletteQuality", "Palette quality", 100, min: 0, max: 100, advanced: true)],
              apply: { img, p in try img.png(options: PNGOptions(compressionLevel: p.int("compressionLevel"), interlaced: p.bool("interlaced"), palette: p.bool("palette") ? PNGPalette(quality: p.int("paletteQuality")) : nil)) },
              swift: { p in
                if !p.bool("palette") { return call("png", [("compressionLevel", String(p.int("compressionLevel")), !p.isDefault("compressionLevel")), ("interlaced", "true", p.bool("interlaced"))]) }
                return ".png(options: PNGOptions(compressionLevel: \(p.int("compressionLevel")), interlaced: \(p.bool("interlaced")), palette: PNGPalette(quality: \(p.int("paletteQuality")))))"
              }),
    OutputDef(format: "webp", title: "WebP", mime: "image/webp", fileExtension: "webp",
              params: [int("quality", "Quality", 82, min: 1, max: 100), int("effort", "Effort", 4, min: 0, max: 6, advanced: true), flag("lossless", "Lossless"),
                       flag("nearLossless", "Near lossless", advanced: true), flag("smartSubsample", "Smart subsample", advanced: true),
                       choice("preset", "Preset", "default", ["default", "picture", "photo", "drawing", "icon", "text"].map { ($0, $0) }, advanced: true)],
              apply: { img, p in
                let preset: WebPPreset = switch p.string("preset") { case "picture": .picture; case "photo": .photo; case "drawing": .drawing; case "icon": .icon; case "text": .text; default: .default }
                return try img.webp(options: WebPOptions(quality: p.int("quality"), effort: p.int("effort"), lossless: p.bool("lossless"), nearLossless: p.bool("nearLossless"), smartSubsample: p.bool("smartSubsample"), preset: preset))
              },
              swift: { p in
                if p.isDefault("nearLossless") && p.isDefault("smartSubsample") && p.isDefault("preset") { return call("webp", [("quality", String(p.int("quality")), true), ("effort", String(p.int("effort")), !p.isDefault("effort")), ("lossless", "true", p.bool("lossless"))]) }
                return opts("webp", [("quality", String(p.int("quality")), true), ("effort", String(p.int("effort")), !p.isDefault("effort")), ("lossless", "true", p.bool("lossless")),
                                     ("nearLossless", "true", p.bool("nearLossless")), ("smartSubsample", "true", p.bool("smartSubsample")), ("preset", "." + p.string("preset"), !p.isDefault("preset"))])
              }),
    OutputDef(format: "avif", title: "AVIF", mime: "image/avif", fileExtension: "avif",
              params: [int("quality", "Quality", 50, min: 1, max: 100), int("effort", "Effort", 4, min: 0, max: 9, advanced: true), flag("lossless", "Lossless"),
                       choice("bitDepth", "Bit depth", "8", [("8", "8"), ("10", "10"), ("12", "12")], advanced: true),
                       choice("chroma", "Chroma subsampling", "automatic", chromaChoices, advanced: true)],
              apply: { img, p in try img.avif(options: AVIFOptions(quality: p.int("quality"), effort: p.int("effort"), lossless: p.bool("lossless"), bitDepth: depth(Int(p.string("bitDepth")) ?? 8), chromaSubsampling: chroma(p.string("chroma")))) },
              swift: { p in
                if p.isDefault("bitDepth") && p.isDefault("chroma") { return call("avif", [("quality", String(p.int("quality")), true), ("effort", String(p.int("effort")), !p.isDefault("effort")), ("lossless", "true", p.bool("lossless"))]) }
                return opts("avif", [("quality", String(p.int("quality")), true), ("effort", String(p.int("effort")), !p.isDefault("effort")), ("lossless", "true", p.bool("lossless")),
                                     ("bitDepth", p.string("bitDepth") == "10" ? ".ten" : p.string("bitDepth") == "12" ? ".twelve" : ".eight", !p.isDefault("bitDepth")), ("chromaSubsampling", "." + p.string("chroma"), !p.isDefault("chroma"))])
              }),
    OutputDef(format: "heif", title: "HEIF", mime: "image/heif", fileExtension: "heic",
              params: [choice("compression", "Compression", "hevc", [("hevc", "HEVC"), ("av1", "AV1")], help: "Which encoders exist depends on the libheif build; this runtime's capabilities say. A missing one is reported as an error."),
                       int("quality", "Quality", 50, min: 1, max: 100), int("effort", "Effort", 4, min: 0, max: 9, advanced: true), flag("lossless", "Lossless")],
              apply: { img, p in try img.heif(options: HEIFOptions(compression: p.string("compression") == "av1" ? .av1 : .hevc, quality: p.int("quality"), effort: p.int("effort"), lossless: p.bool("lossless"))) },
              swift: { p in opts("heif", [("compression", "." + p.string("compression"), true), ("quality", String(p.int("quality")), true), ("effort", String(p.int("effort")), !p.isDefault("effort")), ("lossless", "true", p.bool("lossless"))]) }),
    OutputDef(format: "tiff", title: "TIFF", mime: "image/tiff", fileExtension: "tiff",
              params: [choice("compression", "Compression", "none", [("none", "None"), ("deflate", "Deflate"), ("lzw", "LZW"), ("packBits", "PackBits")])],
              apply: { img, p in
                let c: TIFFCompression = switch p.string("compression") { case "deflate": .deflate; case "lzw": .lzw; case "packBits": .packBits; default: .none }
                return try img.tiff(compression: c)
              },
              swift: { p in call("tiff", [("compression", "." + p.string("compression"), !p.isDefault("compression"))]) }),
    OutputDef(format: "gif", title: "GIF", mime: "image/gif", fileExtension: "gif", params: [],
              apply: { img, _ in try img.gif() }, swift: { _ in ".gif()" }),
    OutputDef(format: "pdf", title: "PDF (raster page)", mime: "application/pdf", fileExtension: "pdf",
              params: [
                choice("pageSize", "Page", "a4", [("image", "Same size as the image"), ("a4", "A4"), ("letter", "US Letter"), ("custom", "Custom (points)")]),
                choice("orientation", "Orientation", "portrait", [("portrait", "Portrait"), ("landscape", "Landscape")], help: "For A4 and Letter."),
                int("margins", "Margins", 36, min: 0, max: 2000, unit: "pt", help: "1 point is 1/72 inch."),
                choice("anchor", "Image position", "center", gravities),
                color("background", "Page background", "#ffffff"),
                text("title", "Document title", ""),
                text("author", "Author", ""),
                int("imageDpi", "Image resolution", 72, min: 1, max: 2400, unit: "dpi", advanced: true, help: "Only for “Same size as the image”: pixels per inch."),
                int("pageWidth", "Custom width", 595, min: 1, max: 14_400, unit: "pt", advanced: true), int("pageHeight", "Custom height", 842, min: 1, max: 14_400, unit: "pt", advanced: true),
                int("maxEffectiveDpi", "Cap effective resolution", 0, min: 0, max: 2400, unit: "dpi", advanced: true, help: "0 keeps every pixel. A cap downsamples images placed on the page."),
              ],
              apply: { img, p in
                var meta = PDFDocumentMetadata()
                if !p.string("title").isEmpty { meta.title = p.string("title") }
                if !p.string("author").isEmpty { meta.author = p.string("author") }
                let m = Double(p.int("margins"))
                return try img.pdf(pageSize: pdfPageSize(p), margins: .all(m), anchor: gravity(p.string("anchor")), background: p.color("background"),
                                   maxEffectiveDPI: p.int("maxEffectiveDpi") == 0 ? nil : Double(p.int("maxEffectiveDpi")),
                                   metadata: meta == PDFDocumentMetadata() ? nil : meta)
              },
              swift: { p in
                let size: String = switch p.string("pageSize") {
                case "a4": p.string("orientation") == "landscape" ? ".a4(.landscape)" : ".a4()"
                case "letter": p.string("orientation") == "landscape" ? ".letter(.landscape)" : ".letter()"
                case "custom": ".points(width: \(p.int("pageWidth")), height: \(p.int("pageHeight")))"
                default: ".image(dpi: \(p.int("imageDpi")))"
                }
                var meta: [String] = []
                if !p.string("title").isEmpty { meta.append("title: \(swiftLiteral(p.string("title")))") }
                if !p.string("author").isEmpty { meta.append("author: \(swiftLiteral(p.string("author")))") }
                return call("pdf", [("pageSize", size, true), ("margins", ".all(\(p.int("margins")))", p.int("margins") != 0),
                                    ("anchor", "." + p.string("anchor"), !p.isDefault("anchor")), ("background", Hex.swift(p.string("background")), true),
                                    ("maxEffectiveDPI", String(p.int("maxEffectiveDpi")), p.int("maxEffectiveDpi") != 0),
                                    ("metadata", "PDFDocumentMetadata(\(meta.joined(separator: ", ")))", !meta.isEmpty)])
              }),
]
