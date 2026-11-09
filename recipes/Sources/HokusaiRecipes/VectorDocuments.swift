import Foundation
import Hokusai
import HokusaiPDF

// A second application-owned model, for HokusaiPDF documents. Like recipes it is plain JSON, is described by
// a catalog (so the Web UI and the macOS app are generated from it), compiles into ordinary public calls and
// prints as Swift. A VectorPage draws text, shapes, gradients and images as PDF content; it is not an editor
// for existing PDFs and has no tables or other layout beyond what HokusaiPDF offers.

public struct VectorItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// An `VectorItemSpec.type`.
    public var type: String
    public var props: [String: ParamValue]
    public init(id: String = UUID().uuidString, type: String, props: [String: ParamValue] = [:]) {
        self.id = id; self.type = type; self.props = props
    }
    private enum CodingKeys: String, CodingKey { case id, type, props }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        props = try c.decodeIfPresent([String: ParamValue].self, forKey: .props) ?? [:]
    }
}

public struct VectorPageSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// `a4`, `letter` or `custom`.
    public var size: String
    public var orientation: String
    /// Points, used by `custom`.
    public var width: Double
    public var height: Double
    /// Drawn in order, later items over earlier ones.
    public var items: [VectorItem]
    public init(id: String = UUID().uuidString, size: String = "a4", orientation: String = "portrait", width: Double = 595, height: Double = 842, items: [VectorItem] = []) {
        self.id = id; self.size = size; self.orientation = orientation; self.width = width; self.height = height; self.items = items
    }
    private enum CodingKeys: String, CodingKey { case id, size, orientation, width, height, items }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        size = try c.decodeIfPresent(String.self, forKey: .size) ?? "a4"
        orientation = try c.decodeIfPresent(String.self, forKey: .orientation) ?? "portrait"
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 595
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 842
        items = try c.decodeIfPresent([VectorItem].self, forKey: .items) ?? []
    }
}

public struct VectorDocumentSpec: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maximumPages = 12
    public static let maximumItemsPerPage = 60
    public var version: Int
    public var title: String
    public var author: String
    public var pages: [VectorPageSpec]
    public init(version: Int = currentVersion, title: String = "", author: String = "", pages: [VectorPageSpec] = []) {
        self.version = version; self.title = title; self.author = author; self.pages = pages
    }
    private enum CodingKeys: String, CodingKey { case version, title, author, pages }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        pages = try c.decodeIfPresent([VectorPageSpec].self, forKey: .pages) ?? []
    }
}

public struct VectorItemSpec: Codable, Sendable {
    public let type: String
    public let title: String
    public let summary: String
    public let api: String
    public let params: [ParamSpec]
}

private let noColor = "#00000000"
private func n(_ name: String, _ label: String, _ def: Double, min: Double? = nil, max: Double? = nil, unit: String? = "pt", advanced: Bool = false, help: String? = nil) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .number, default: .number(def), min: min, max: max, step: 1, unit: unit, options: nil, advanced: advanced, help: help)
}
private func col(_ name: String, _ label: String, _ def: String, help: String? = nil) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .color, default: .string(def), min: nil, max: nil, step: nil, unit: nil, options: nil, advanced: false, help: help)
}
private func flg(_ name: String, _ label: String, _ def: Bool = false, advanced: Bool = false, help: String? = nil) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .boolean, default: .bool(def), min: nil, max: nil, step: nil, unit: nil, options: nil, advanced: advanced, help: help)
}
private func pick(_ name: String, _ label: String, _ def: String, _ options: [(String, String)], advanced: Bool = false) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .choice, default: .string(def), min: nil, max: nil, step: nil, unit: nil,
              options: options.map { Choice(value: $0.0, label: $0.1) }, advanced: advanced, help: nil)
}
private func txt(_ name: String, _ label: String, _ def: String) -> ParamSpec {
    ParamSpec(name: name, label: label, kind: .text, default: .string(def), min: nil, max: nil, step: nil, unit: nil, options: nil, advanced: false, help: nil)
}

/// The assets an image item can place. `upload` is the image the visitor opened.
public let vectorAssetChoices: [(String, String)] = [("scene.png", "Scene"), ("emblem.png", "Emblem (transparent)"), ("phone.jpg", "Phone photo"), ("upload", "My upload")]

public enum VectorCatalog {
    public static let items: [VectorItemSpec] = [
        VectorItemSpec(type: "background", title: "Background", summary: "Fills the whole page with a colour or a two-colour gradient.", api: "background(_:)", params: [
            col("fill", "Colour", "#ffffff"), flg("gradient", "Gradient", false), col("fill2", "Second colour", "#1b3a57"), n("angle", "Gradient angle", 90, min: -360, max: 360, unit: "°"),
        ]),
        VectorItemSpec(type: "rect", title: "Rectangle", summary: "A filled and/or outlined rectangle. Make the fill or the outline transparent to leave it out; it needs one of them.", api: "rectangle(_:fill:stroke:cornerRadius:)", params: [
            n("x", "Left", 36, min: -20_000, max: 20_000), n("y", "Top", 36, min: -20_000, max: 20_000), n("width", "Width", 200, min: 1, max: 20_000), n("height", "Height", 100, min: 1, max: 20_000),
            col("fill", "Fill", "#1b3a57"), col("stroke", "Outline", noColor), n("strokeWidth", "Outline width", 1, min: 0.1, max: 100), n("radius", "Corner radius", 0, min: 0, max: 1000),
        ]),
        VectorItemSpec(type: "line", title: "Line", summary: "A straight line between two points.", api: "line(from:to:stroke:)", params: [
            n("x", "From x", 36, min: -20_000, max: 20_000), n("y", "From y", 120, min: -20_000, max: 20_000), n("x2", "To x", 559, min: -20_000, max: 20_000), n("y2", "To y", 120, min: -20_000, max: 20_000),
            col("stroke", "Colour", "#1b3a57"), n("strokeWidth", "Width", 1, min: 0.1, max: 100),
        ]),
        VectorItemSpec(type: "text", title: "Text", summary: "Real text: selectable and searchable in a PDF viewer. Markup uses Pango tags such as <b>bold</b> and <i>italic</i>.", api: "text(_:at:width:style:)", params: [
            txt("content", "Text", "Hello, PDF"), flg("markup", "Pango markup", false),
            n("x", "Left", 36, min: -20_000, max: 20_000), n("y", "Top", 36, min: -20_000, max: 20_000), n("width", "Wrap width", 0, min: 0, max: 20_000),
            n("size", "Size", 14, min: 1, max: 1000), pick("family", "Font", "sans", [("sans", "Sans"), ("serif", "Serif"), ("monospace", "Monospace")]),
            pick("weight", "Weight", "regular", [("thin", "Thin"), ("light", "Light"), ("regular", "Regular"), ("medium", "Medium"), ("semibold", "Semibold"), ("bold", "Bold"), ("heavy", "Heavy"), ("black", "Black")]),
            flg("italic", "Italic"), col("color", "Colour", "#1c2733"),
            pick("alignment", "Alignment", "leading", [("leading", "Left"), ("center", "Centre"), ("trailing", "Right"), ("justified", "Justified")], advanced: true),
            n("lineSpacing", "Line spacing", 1, min: 0.5, max: 5, unit: "×", advanced: true),
        ]),
        VectorItemSpec(type: "image", title: "Image", summary: "Places a picture, embedded as a raster, inside a frame.", api: "image(_:frame:fit:opacity:)", params: [
            pick("asset", "Picture", "scene.png", vectorAssetChoices),
            n("x", "Left", 36, min: -20_000, max: 20_000), n("y", "Top", 36, min: -20_000, max: 20_000), n("width", "Width", 300, min: 1, max: 20_000), n("height", "Height", 200, min: 1, max: 20_000),
            pick("fit", "Fit", "contain", [("contain", "Contain"), ("cover", "Cover (crop)"), ("fill", "Fill (stretch)")]), n("opacity", "Opacity", 1, min: 0, max: 1, unit: nil),
        ]),
    ]
    static let byType = Dictionary(uniqueKeysWithValues: items.map { ($0.type, $0) })
}

public enum VectorError: Error, CustomStringConvertible, Equatable {
    case unsupportedVersion(Int)
    case unknownItem(String)
    case noPages
    case tooManyPages
    case tooManyItems(page: Int)
    case unknownAsset(String)
    case noUpload

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): "document version \(v) is not supported (current is \(VectorDocumentSpec.currentVersion))"
        case .unknownItem(let t): "unknown item type '\(t)'"
        case .noPages: "a document needs at least one page"
        case .tooManyPages: "a document may have at most \(VectorDocumentSpec.maximumPages) pages"
        case .tooManyItems(let p): "page \(p) has more than \(VectorDocumentSpec.maximumItemsPerPage) items"
        case .unknownAsset(let a): "unknown picture '\(a)'"
        case .noUpload: "this document uses “My upload”, but no image has been opened"
        }
    }
}

public enum VectorCompiler {
    /// Resolves a picture name to a pipeline. The caller owns where the pictures come from.
    public typealias Assets = @Sendable (String) throws -> Hokusai

    public static func validate(_ doc: VectorDocumentSpec) throws {
        guard doc.version == VectorDocumentSpec.currentVersion else { throw VectorError.unsupportedVersion(doc.version) }
        guard !doc.pages.isEmpty else { throw VectorError.noPages }
        guard doc.pages.count <= VectorDocumentSpec.maximumPages else { throw VectorError.tooManyPages }
        for (i, page) in doc.pages.enumerated() {
            guard page.items.count <= VectorDocumentSpec.maximumItemsPerPage else { throw VectorError.tooManyItems(page: i + 1) }
            for item in page.items { _ = try params(for: item) }
        }
    }

    static func params(for item: VectorItem) throws -> Params {
        guard let spec = VectorCatalog.byType[item.type] else { throw VectorError.unknownItem(item.type) }
        return try Params(operation: item.type, specs: spec.params, values: item.props)
    }

    private static func pageSize(_ page: VectorPageSpec) -> VectorPageSize {
        let o: PDFPageOrientation = page.orientation == "landscape" ? .landscape : .portrait
        switch page.size {
        case "letter": return .letter(o)
        case "custom": return .points(width: page.width, height: page.height)
        default: return .a4(o)
        }
    }

    private static func weight(_ name: String) -> VectorFontWeight {
        switch name {
        case "thin": .thin; case "light": .light; case "medium": .medium; case "semibold": .semibold
        case "bold": .bold; case "heavy": .heavy; case "black": .black; default: .regular
        }
    }
    private static func alignment(_ name: String) -> VectorTextAlignment {
        switch name { case "center": .center; case "trailing": .trailing; case "justified": .justified; default: .leading }
    }
    private static func visible(_ c: Color) -> Color? { c.opacity == 0 ? nil : c }

    public static func compile(_ doc: VectorDocumentSpec, assets: Assets) throws -> VectorDocument {
        try validate(doc)
        var pages: [VectorPage] = []
        for spec in doc.pages {
            var page = try VectorPage(size: pageSize(spec))
            for item in spec.items {
                let p = try params(for: item)
                switch item.type {
                case "background":
                    page = try page.background(p.bool("gradient") ? .linearGradient(from: p.color("fill"), to: p.color("fill2"), angle: p.double("angle")) : .color(p.color("fill")))
                case "rect":
                    let stroke = visible(p.color("stroke")).map { VectorStroke(color: $0, width: p.double("strokeWidth")) }
                    page = try page.rectangle(VectorRect(x: p.double("x"), y: p.double("y"), width: p.double("width"), height: p.double("height")),
                                              fill: visible(p.color("fill")).map { .color($0) }, stroke: stroke, cornerRadius: p.double("radius"))
                case "line":
                    page = try page.line(from: VectorPoint(x: p.double("x"), y: p.double("y")), to: VectorPoint(x: p.double("x2"), y: p.double("y2")),
                                         stroke: VectorStroke(color: p.color("stroke"), width: p.double("strokeWidth")))
                case "text":
                    let content: TextContent = p.bool("markup") ? .markup(p.string("content")) : .plain(p.string("content"))
                    let style = VectorTextStyle(family: p.string("family"), size: p.double("size"), weight: weight(p.string("weight")), italic: p.bool("italic"),
                                                color: p.color("color"), alignment: alignment(p.string("alignment")), lineSpacing: p.double("lineSpacing"))
                    page = try page.text(content, at: VectorPoint(x: p.double("x"), y: p.double("y")), width: p.double("width") > 0 ? p.double("width") : nil, style: style)
                case "image":
                    let fit: VectorImageFit = p.string("fit") == "cover" ? .cover : p.string("fit") == "fill" ? .fill : .contain
                    page = try page.image(try assets(p.string("asset")), frame: VectorRect(x: p.double("x"), y: p.double("y"), width: p.double("width"), height: p.double("height")),
                                          fit: fit, opacity: p.double("opacity"))
                default: throw VectorError.unknownItem(item.type)
                }
            }
            pages.append(page)
        }
        var meta = PDFDocumentMetadata()
        if !doc.title.isEmpty { meta.title = doc.title }
        if !doc.author.isEmpty { meta.author = doc.author }
        return VectorDocument(pages: pages, metadata: meta == PDFDocumentMetadata() ? nil : meta)
    }
}

public enum VectorCodeGenerator {
    private static func num(_ v: Double) -> String { format(v) }

    public static func swift(_ doc: VectorDocumentSpec) throws -> String {
        try VectorCompiler.validate(doc)
        var out = ["import Foundation", "import Hokusai", "import HokusaiPDF", ""]
        var names: [String] = []
        for (index, spec) in doc.pages.enumerated() {
            let name = "page\(index + 1)"
            names.append(name)
            let size: String = switch spec.size {
            case "letter": spec.orientation == "landscape" ? ".letter(.landscape)" : ".letter()"
            case "custom": ".points(width: \(num(spec.width)), height: \(num(spec.height)))"
            default: spec.orientation == "landscape" ? ".a4(.landscape)" : ".a4()"
            }
            out.append("let \(name) = try VectorPage(size: \(size))")
            for item in spec.items {
                let p = try VectorCompiler.params(for: item)
                func c(_ n: String) -> String { Hex.swift(p.string(n)) }
                func rect() -> String { "VectorRect(x: \(num(p.double("x"))), y: \(num(p.double("y"))), width: \(num(p.double("width"))), height: \(num(p.double("height"))))" }
                switch item.type {
                case "background":
                    out.append("    .background(\(p.bool("gradient") ? ".linearGradient(from: \(c("fill")), to: \(c("fill2")), angle: \(num(p.double("angle"))))" : ".color(\(c("fill")))"))")
                case "rect":
                    var args = [rect()]
                    if Hex.parse(p.string("fill"))?.opacity != 0 { args.append("fill: .color(\(c("fill")))") }
                    if Hex.parse(p.string("stroke"))?.opacity != 0 { args.append("stroke: VectorStroke(color: \(c("stroke")), width: \(num(p.double("strokeWidth"))))") }
                    if p.double("radius") != 0 { args.append("cornerRadius: \(num(p.double("radius")))") }
                    out.append("    .rectangle(\(args.joined(separator: ", ")))")
                case "line":
                    out.append("    .line(from: VectorPoint(x: \(num(p.double("x"))), y: \(num(p.double("y")))), to: VectorPoint(x: \(num(p.double("x2"))), y: \(num(p.double("y2")))), stroke: VectorStroke(color: \(c("stroke")), width: \(num(p.double("strokeWidth")))))")
                case "text":
                    var style = ["family: \(swiftLiteral(p.string("family")))", "size: \(num(p.double("size")))"]
                    if p.string("weight") != "regular" { style.append("weight: .\(p.string("weight"))") }
                    if p.bool("italic") { style.append("italic: true") }
                    style.append("color: \(c("color"))")
                    if p.string("alignment") != "leading" { style.append("alignment: .\(p.string("alignment"))") }
                    if p.double("lineSpacing") != 1 { style.append("lineSpacing: \(num(p.double("lineSpacing")))") }
                    let content = "\(p.bool("markup") ? ".markup" : ".plain")(\(swiftLiteral(p.string("content"))))"
                    let width = p.double("width") > 0 ? ", width: \(num(p.double("width")))" : ""
                    out.append("    .text(\(content), at: VectorPoint(x: \(num(p.double("x"))), y: \(num(p.double("y"))))\(width), style: VectorTextStyle(\(style.joined(separator: ", "))))")
                case "image":
                    let asset = p.string("asset") == "upload" ? "photo.jpg" : p.string("asset")     // placeholder: the demo's upload is not a file you have
                    var args = ["try Hokusai(url: URL(fileURLWithPath: \(swiftLiteral(asset))))", "frame: \(rect().replacingOccurrences(of: "VectorRect", with: "VectorRect"))"]
                    if p.string("fit") != "contain" { args.append("fit: .\(p.string("fit"))") }
                    if p.double("opacity") != 1 { args.append("opacity: \(num(p.double("opacity")))") }
                    out.append("    .image(\(args.joined(separator: ", ")))")
                default: break
                }
            }
            out.append("")
        }
        var meta: [String] = []
        if !doc.title.isEmpty { meta.append("title: \(swiftLiteral(doc.title))") }
        if !doc.author.isEmpty { meta.append("author: \(swiftLiteral(doc.author))") }
        out.append("let document = VectorDocument(pages: [\(names.joined(separator: ", "))]\(meta.isEmpty ? "" : ", metadata: PDFDocumentMetadata(\(meta.joined(separator: ", ")))"))")
        out.append("let info = try await document.write(to: URL(fileURLWithPath: \"document.pdf\"))")
        out.append("print(\"\\(info.pageCount) pages, \\(info.byteCount) bytes\")")
        return out.joined(separator: "\n")
    }
}

public enum VectorPresets {
    private static func item(_ type: String, _ props: [String: ParamValue]) -> VectorItem { VectorItem(id: UUID().uuidString, type: type, props: props) }
    private static func v(_ x: Double) -> ParamValue { .number(x) }

    /// A two-page report: a cover with a gradient, a picture and a title, then a page of text and shapes.
    public static let report = VectorDocumentSpec(title: "Lighthouse report", author: "Hokusai examples", pages: [
        VectorPageSpec(items: [
            item("background", ["gradient": .bool(true), "fill": .string("#1b3a57"), "fill2": .string("#2f7d8c"), "angle": v(90)]),
            item("image", ["asset": .string("scene.png"), "x": v(48), "y": v(150), "width": v(499), "height": v(312), "fit": .string("cover")]),
            item("text", ["content": .string("Lighthouse report"), "x": v(48), "y": v(60), "size": v(34), "weight": .string("bold"), "color": .string("#ffffff")]),
            item("text", ["content": .string("Text is real text: select it in your PDF viewer."), "x": v(48), "y": v(112), "size": v(14), "color": .string("#f1ead8")]),
        ]),
        VectorPageSpec(items: [
            item("rect", ["x": v(0), "y": v(0), "width": v(595), "height": v(90), "fill": .string("#1b3a57")]),
            item("text", ["content": .string("Findings"), "x": v(48), "y": v(30), "size": v(26), "weight": .string("semibold"), "color": .string("#ffffff")]),
            item("line", ["x": v(48), "y": v(120), "x2": v(547), "y2": v(120), "stroke": .string("#c0561f"), "strokeWidth": v(2)]),
            item("text", ["content": .string("The <b>beam</b> sweeps the bay every <i>ten seconds</i>. Shapes stay sharp at any zoom and the words below can be searched.\n\nImages placed on a page are embedded as rasters prepared by an ordinary Hokusai pipeline."),
                          "markup": .bool(true), "x": v(48), "y": v(140), "width": v(499), "size": v(13), "lineSpacing": v(1.3)]),
            item("rect", ["x": v(48), "y": v(300), "width": v(220), "height": v(110), "fill": .string("#f1ead8"), "stroke": .string("#1b3a57"), "strokeWidth": v(1.5), "radius": v(10)]),
            item("image", ["asset": .string("emblem.png"), "x": v(300), "y": v(300), "width": v(110), "height": v(110)]),
        ]),
    ])

    public static let all: [(id: String, title: String, doc: VectorDocumentSpec)] = [("report", "Two-page report", report)]
}
