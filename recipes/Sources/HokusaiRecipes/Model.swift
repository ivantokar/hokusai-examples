import Foundation

/// One parameter value. Recipes are plain JSON, so values are numbers, strings or booleans.
public enum ParamValue: Codable, Hashable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected a number, string or boolean") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        }
    }
}

public enum ParamKind: String, Codable, Sendable { case number, integer, boolean, choice, color, text, matrix }

public struct Choice: Codable, Hashable, Sendable {
    public let value: String
    public let label: String
    public init(value: String, label: String) { self.value = value; self.label = label }
}

/// A grid of numbers, stored in a recipe as one string of space-separated values, row by row.
public struct MatrixSpec: Codable, Sendable {
    /// Columns when fixed, for example 3 for a colour matrix.
    public var columns: Int?
    /// The name of a sibling parameter whose value is the side of a square grid, for a kernel whose size is chosen.
    public var columnsFrom: String?
    /// Named starting points. Picking one sets the grid and any sibling parameters it names.
    public var presets: [MatrixPreset]

    /// The identity grid of a side, in the string form a recipe stores.
    public static func identity(side: Int) -> String {
        (0..<side * side).map { $0 % (side + 1) == 0 ? "1" : "0" }.joined(separator: " ")
    }
}

public struct MatrixPreset: Codable, Sendable {
    public let label: String
    public let values: String
    /// Sibling parameters the preset also sets (the kernel's size, scale, offset).
    public let params: [String: ParamValue]
}

/// Describes one control: its type, unit, default and range. The Web UI is generated from this.
public struct ParamSpec: Codable, Sendable {
    public let name: String
    public let label: String
    public let kind: ParamKind
    public let `default`: ParamValue
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var unit: String?
    public var options: [Choice]?
    /// Shown under "Advanced" instead of next to the common controls.
    public var advanced: Bool
    public var help: String?
    /// For `matrix` parameters: the grid's shape and presets.
    public var matrix: MatrixSpec? = nil
}

public enum OperationGroup: String, Codable, CaseIterable, Sendable {
    case geometry, effects, color, composition
}

/// The documented meaning of one operation and the public Hokusai call it maps to.
public struct OperationSpec: Codable, Sendable {
    public let id: String
    public let title: String
    public let group: OperationGroup
    /// The public API this friendly name maps to, for example `extract(x:y:width:height:)`.
    public let api: String
    public let summary: String
    public let params: [ParamSpec]
    /// Where the preview can differ from the export, in plain language.
    public var previewNote: String?
}

/// Output configuration. It is not a pixel transform, so it lives outside the step list.
public struct OutputSettings: Codable, Hashable, Sendable {
    public var format: String
    public var options: [String: ParamValue]
    public init(format: String = "jpeg", options: [String: ParamValue] = [:]) {
        self.format = format
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case format, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        options = try c.decodeIfPresent([String: ParamValue].self, forKey: .options) ?? [:]
    }
}

public struct Step: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// An `OperationSpec.id`.
    public var op: String
    public var enabled: Bool
    public var params: [String: ParamValue]

    public init(id: String = UUID().uuidString, op: String, enabled: Bool = true, params: [String: ParamValue] = [:]) {
        self.id = id
        self.op = op
        self.enabled = enabled
        self.params = params
    }

    private enum CodingKeys: String, CodingKey { case id, op, enabled, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(String.self, forKey: .op)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        params = try c.decodeIfPresent([String: ParamValue].self, forKey: .params) ?? [:]
    }
}

/// An application-owned, versioned description of a pipeline. It compiles to ordinary public
/// Hokusai calls; Hokusai's own plan is never serialised.
public struct Recipe: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var name: String?
    /// Ordered. Repeating an operation is allowed and the order is kept.
    public var steps: [Step]
    public var output: OutputSettings

    public init(version: Int = Recipe.currentVersion, name: String? = nil, steps: [Step] = [], output: OutputSettings = .init()) {
        self.version = version
        self.name = name
        self.steps = steps
        self.output = output
    }
}

public enum RecipeError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case unknownOperation(String)
    case unknownParameter(operation: String, name: String)
    case invalidParameter(operation: String, name: String, reason: String)
    case unknownFormat(String)
    case tooManySteps(Int)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): "recipe version \(v) is not supported (current is \(Recipe.currentVersion))"
        case .unknownOperation(let op): "unknown operation '\(op)'"
        case .unknownParameter(let op, let name): "operation '\(op)' has no parameter '\(name)'"
        case .invalidParameter(let op, let name, let reason): "\(op) → \(name): \(reason)"
        case .unknownFormat(let f): "unknown output format '\(f)'"
        case .tooManySteps(let n): "a recipe may have at most \(n) steps"
        }
    }
}
