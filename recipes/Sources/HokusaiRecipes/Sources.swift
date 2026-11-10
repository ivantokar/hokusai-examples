import Foundation
import Hokusai

/// A generated source: pixels that do not come from an uploaded image. It is described like an operation
/// (parameters, units, defaults), so the Web UI and the macOS inspector draw its controls from the catalog.
struct SourceDef: Sendable {
    let spec: OperationSpec
    /// The pipeline the recipe starts from.
    let make: @Sendable (Params) throws -> Hokusai
    /// A Swift expression for the source, then the chained calls that follow it.
    let swift: @Sendable (Params) -> (expression: String, chain: [String])
}

private let sourceAlignments: [(String, String)] = [("left", "Left"), ("center", "Centre"), ("right", "Right")]

private func lines(_ content: String) -> String { content.replacingOccurrences(of: "\\n", with: "\n") }

let allSources: [SourceDef] = [
    SourceDef(
        spec: OperationSpec(id: "text", title: "Text", group: .composition, api: "Hokusai.text(_:layout:style:)",
            summary: "An image made from text: no photo needed. Set the font, size and colour, wrap it at a width, and give it a background and padding.",
            params: [
                text("content", "Text", "Hokusai\\nimage processing for Swift", help: "Type \\n for a new line."),
                int("fontSize", "Size", 120, min: 6, max: 600, unit: "pt"),
                choice("font", "Font", "sans bold", [("sans", "Sans"), ("sans bold", "Sans bold"), ("serif", "Serif"), ("serif bold", "Serif bold"), ("monospace", "Monospace")]),
                color("color", "Text colour", "#1b3a57"),
                choice("alignment", "Alignment", "center", sourceAlignments),
                color("background", "Background", "#fffdf7", help: "Fully transparent keeps the alpha channel."),
                int("padding", "Padding", 64, min: 0, max: 2000, unit: "px"),
                int("wrapWidth", "Wrap at", 0, min: 0, max: 4000, unit: "px", advanced: true, help: "0 keeps the text as wide as it needs; lines then break only at newlines."),
                num("lineHeight", "Line height", 1, min: 0.5, max: 5, step: 0.05, unit: "×", advanced: true),
            ],
            previewNote: "Text size is in image pixels at 72 dpi."),
        make: { p in
            let content = lines(p.string("content"))
            guard !content.isEmpty else { throw RecipeError.invalidParameter(operation: "text", name: "content", reason: "cannot be empty") }
            let layout: TextLayout = p.int("wrapWidth") > 0 ? .width(p.int("wrapWidth")) : .natural
            var image = try Hokusai.text(.plain(content), layout: layout, style: textStyle(p))
            let background = p.color("background")
            if p.int("padding") > 0 {
                image = try image.extend(top: p.int("padding"), left: p.int("padding"), bottom: p.int("padding"), right: p.int("padding"), mode: .background(background))
            }
            if background.opacity > 0 { image = try image.flatten(background: background) }
            return image
        },
        swift: { p in
            let layout = p.int("wrapWidth") > 0 ? ", layout: .width(\(p.int("wrapWidth")))" : ""
            var style = "font: \(swiftLiteral(p.string("font"))), fontSize: \(p.int("fontSize")), color: \(Hex.swift(p.string("color")))"
            if p.string("alignment") != "left" { style += ", alignment: .\(p.string("alignment"))" }
            if !p.isDefault("lineHeight") || p.double("lineHeight") != 1 { style += ", lineHeight: \(format(p.double("lineHeight")))" }
            let expression = "try Hokusai.text(\(swiftLiteral(lines(p.string("content"))))\(layout), style: TextStyle(\(style)))"
            let background = Hex.swift(p.string("background"))
            var chain: [String] = []
            if p.int("padding") > 0 { chain.append(".extend(top: \(p.int("padding")), left: \(p.int("padding")), bottom: \(p.int("padding")), right: \(p.int("padding")), mode: .background(\(background)))") }
            if p.color("background").opacity > 0 { chain.append(".flatten(background: \(background))") }
            return (expression, chain)
        }),
]

private func textStyle(_ p: Params) -> TextStyle {
    let alignment: TextAlignment = switch p.string("alignment") { case "left": .left; case "right": .right; default: .center }
    return TextStyle(font: p.string("font"), fontSize: p.int("fontSize"), color: p.color("color"), alignment: alignment, lineHeight: p.double("lineHeight"))
}

public enum RecipeSources {
    private static let sources = Dictionary(uniqueKeysWithValues: allSources.map { ($0.spec.id, $0) })

    public static var catalog: [OperationSpec] { allSources.map(\.spec) }

    static func definition(_ source: RecipeSource) throws -> (SourceDef, Params) {
        guard let def = sources[source.kind] else { throw RecipeError.unknownSource(source.kind) }
        return (def, try Params(operation: source.kind, specs: def.spec.params, values: source.params))
    }

    public static func validate(_ source: RecipeSource) throws { _ = try definition(source) }

    public static func make(_ source: RecipeSource) throws -> Hokusai {
        let (def, params) = try definition(source)
        return try def.make(params)
    }

    static func swift(_ source: RecipeSource) throws -> (expression: String, chain: [String]) {
        let (def, params) = try definition(source)
        return def.swift(params)
    }
}
