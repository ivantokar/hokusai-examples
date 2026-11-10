import Foundation
import Hokusai

/// Typed, validated access to a step's parameters, falling back to the catalog defaults.
struct Params {
    let operation: String
    private let specs: [String: ParamSpec]
    private let values: [String: ParamValue]

    init(operation: String, specs: [ParamSpec], values: [String: ParamValue]) throws {
        self.operation = operation
        self.specs = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
        for (name, value) in values {
            guard let spec = self.specs[name] else { throw RecipeError.unknownParameter(operation: operation, name: name) }
            try Params.check(value, against: spec, operation: operation)
        }
        self.values = values
    }

    private static func check(_ value: ParamValue, against spec: ParamSpec, operation: String) throws {
        func bad(_ reason: String) -> RecipeError { .invalidParameter(operation: operation, name: spec.name, reason: reason) }
        switch (spec.kind, value) {
        case (.number, .number(let n)), (.integer, .number(let n)):
            guard n.isFinite else { throw bad("must be finite") }
            if spec.kind == .integer, n != n.rounded() { throw bad("must be a whole number") }
            if let min = spec.min, n < min { throw bad("must be at least \(format(min))") }
            if let max = spec.max, n > max { throw bad("must be at most \(format(max))") }
        case (.boolean, .bool): break
        case (.choice, .string(let s)):
            guard spec.options?.contains(where: { $0.value == s }) == true else { throw bad("'\(s)' is not one of the options") }
        case (.color, .string(let s)):
            guard Hex.parse(s) != nil else { throw bad("expected a colour such as #1a2b3c or #1a2b3c80") }
        case (.text, .string(let s)):
            guard s.utf8.count <= 2_000 else { throw bad("is limited to 2000 bytes") }
        case (.matrix, .string(let s)):
            guard s.utf8.count <= 20_000 else { throw bad("is limited to 20000 bytes") }
            guard Params.parseNumbers(s) != nil else { throw bad("expected numbers separated by spaces") }
        default: throw bad("has the wrong type")
        }
    }

    static func parseNumbers(_ text: String) -> [Double]? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
        let numbers = parts.compactMap { Double($0) }
        return numbers.count == parts.count && numbers.allSatisfy(\.isFinite) ? numbers : nil
    }

    private func value(_ name: String) -> ParamValue {
        values[name] ?? specs[name]!.default
    }

    func double(_ name: String) -> Double { if case .number(let n) = value(name) { n } else { 0 } }
    func int(_ name: String) -> Int { Int(double(name)) }
    func bool(_ name: String) -> Bool { if case .bool(let b) = value(name) { b } else { false } }
    func string(_ name: String) -> String { if case .string(let s) = value(name) { s } else { "" } }
    /// The numbers of a `matrix` parameter, row by row.
    func numbers(_ name: String) -> [Double] { Params.parseNumbers(string(name)) ?? [] }
    func color(_ name: String) -> Color { Hex.parse(string(name)) ?? .transparent }
    func isDefault(_ name: String) -> Bool { value(name) == specs[name]!.default }
}

public enum Hex {
    /// `#rrggbb` or `#rrggbbaa`.
    public static func parse(_ text: String) -> Color? {
        guard text.hasPrefix("#"), text.count == 7 || text.count == 9 else { return nil }
        let digits = Array(text.dropFirst())
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        func byte(_ i: Int) -> UInt8 { UInt8(String(digits[i..<i + 2]), radix: 16)! }
        return .sRGB8(red: byte(0), green: byte(2), blue: byte(4), alpha: digits.count == 8 ? byte(6) : 255)
    }

    /// The Swift expression for a colour: `.white`, `.transparent`, or `.sRGB8(...)`.
    static func swift(_ text: String) -> String {
        guard let c = parse(text) else { return ".transparent" }
        if c == .transparent { return ".transparent" }
        if c == .white { return ".white" }
        func b(_ v: Double) -> Int { Int((v * 255).rounded()) }
        let alpha = b(c.opacity)
        let base = ".sRGB8(red: \(b(c.red)), green: \(b(c.green)), blue: \(b(c.blue))"
        return alpha == 255 ? base + ")" : base + ", alpha: \(alpha))"
    }
}

func format(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
}

/// A Swift string literal for arbitrary user text: quotes, backslashes (which would otherwise start
/// an interpolation), newlines and control characters are escaped.
func swiftLiteral(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where scalar.value < 0x20 || scalar.value == 0x7f: out += "\\u{\(String(scalar.value, radix: 16))}"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}
