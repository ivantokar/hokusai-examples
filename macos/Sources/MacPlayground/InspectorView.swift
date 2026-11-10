import HokusaiRecipes
import PlaygroundModel
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Environment(Playground.self) private var playground
    @State private var choosing = false

    var body: some View {
        ScrollView {
            if let step = playground.recipe.steps.first(where: { $0.id == playground.selection }),
               let spec = Catalog.operations.first(where: { $0.id == step.op }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(spec.title).font(.title3.weight(.semibold))
                    Text(spec.api).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(spec.summary)
                    if let note = spec.previewNote { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    ForEach(spec.params.filter { !$0.advanced }, id: \.name) { p in
                        control(p, step: step, operation: spec)
                    }
                    let advanced = spec.params.filter(\.advanced)
                    if !advanced.isEmpty {
                        DisclosureGroup("Advanced") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(advanced, id: \.name) { p in
                                    control(p, step: step, operation: spec)
                                }
                            }.padding(.top, 8)
                        }
                    }
                    if (step.op == "layer" || step.op == "mask"), case .string("second") = step.params["asset"] ?? .string("") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Second image").fontWeight(.medium)
                            Text(playground.secondImageName.map { "Using \($0)." } ?? "Choose the picture to place.").font(.caption).foregroundStyle(.secondary)
                            Button("Choose…") { choosing = true }
                        }
                    }
                    if !spec.params.isEmpty {
                        Button("Reset to defaults") { for p in spec.params { playground.setParam(step: step.id, p, to: nil) } }
                    }
                }
                .padding(16)
            } else {
                ContentUnavailableView("No step selected", systemImage: "slider.horizontal.3", description: Text("Select a step in the pipeline to edit it."))
                    .padding(.top, 40)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { playground.setSecondImage(data: data, name: url.lastPathComponent) }
        }
    }
}

extension InspectorView {
    /// One parameter's control. A kernel's grid follows its size, so choosing a size starts a new identity grid.
    func control(_ p: ParamSpec, step: Step, operation: OperationSpec) -> some View {
        ParamControl(spec: p, value: step.params[p.name],
                     sibling: { name in step.params[name] ?? operation.params.first { $0.name == name }?.default },
                     setMany: { playground.setParams(step: step.id, $0) }) { value in
            let followers = operation.params.filter { $0.matrix?.columnsFrom == p.name }
            if !followers.isEmpty, case .string(let size)? = value, let side = Int(size) {
                var values: [String: ParamValue] = [p.name: .string(size)]
                for f in followers { values[f.name] = .string(MatrixSpec.identity(side: side)) }
                playground.setParams(step: step.id, values)
            } else {
                playground.setParam(step: step.id, p, to: value)
            }
        }
    }
}

/// One control, generated from the catalog's description of a parameter.
struct ParamControl: View {
    let spec: ParamSpec
    let value: ParamValue?
    var sibling: (String) -> ParamValue? = { _ in nil }
    var setMany: ([String: ParamValue]) -> Void = { _ in }
    let set: (ParamValue?) -> Void

    private var current: ParamValue { value ?? spec.default }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch spec.kind {
            case .number, .integer:
                HStack { Text(spec.label).fontWeight(.medium); Spacer(); if let unit = spec.unit { Text(unit).foregroundStyle(.secondary) } }
                HStack {
                    if let lo = spec.min, let hi = spec.max, hi - lo <= 100_000 {
                        Slider(value: numberBinding, in: lo...hi, step: spec.step ?? (spec.kind == .integer ? 1 : 0.01)) { Text(spec.label) }.labelsHidden()
                    }
                    TextField(spec.label, value: numberBinding, format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder).frame(width: 78).multilineTextAlignment(.trailing)
                }
            case .boolean:
                Toggle(spec.label, isOn: Binding(get: { if case .bool(let b) = current { b } else { false } }, set: { set(.bool($0)) }))
            case .choice:
                Picker(spec.label, selection: Binding(get: { if case .string(let s) = current { s } else { "" } }, set: { set(.string($0)) })) {
                    ForEach(spec.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
                }
            case .color:
                ColorPicker(spec.label, selection: Binding(get: { Self.color(from: current) }, set: { set(.string(Self.hex(from: $0))) }), supportsOpacity: true)
            case .matrix:
                matrixControl
            case .text:
                Text(spec.label).fontWeight(.medium)
                TextField(spec.label, text: Binding(get: { if case .string(let s) = current { s } else { "" } }, set: { set(.string($0)) }))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            if let help = spec.help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// The grid is square: its side is fixed, or read from the sibling parameter that chooses it.
    private var side: Int {
        if let columns = spec.matrix?.columns { return columns }
        if let from = spec.matrix?.columnsFrom, case .string(let s)? = sibling(from), let n = Int(s) { return n }
        return 3
    }

    private var cells: [Double] {
        guard case .string(let s) = current else { return [] }
        var numbers = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).compactMap { Double($0) }
        while numbers.count < side * side { numbers.append(0) }
        return numbers
    }

    @ViewBuilder private var matrixControl: some View {
        HStack {
            Text(spec.label).fontWeight(.medium)
            Spacer()
            if let presets = spec.matrix?.presets, !presets.isEmpty {
                Menu("Start from…") {
                    ForEach(presets.indices, id: \.self) { i in
                        Button(presets[i].label) { setMany([spec.name: .string(presets[i].values)].merging(presets[i].params) { $1 }) }
                    }
                }.fixedSize()
            }
        }
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<side, id: \.self) { row in
                GridRow {
                    ForEach(0..<side, id: \.self) { column in
                        let index = row * side + column
                        TextField("\(spec.label) row \(row + 1) column \(column + 1)",
                                  value: Binding(get: { cells[index] }, set: { new in
                                      var all = cells; all[index] = new
                                      set(.string(all.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }.joined(separator: " ")))
                                  }), format: .number.precision(.fractionLength(0...4)))
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.center).labelsHidden()
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }

    private var numberBinding: Binding<Double> {
        Binding(get: { if case .number(let n) = current { n } else { 0 } },
                set: { set(.number(spec.kind == .integer ? $0.rounded() : $0)) })
    }

    static func color(from value: ParamValue) -> Color {
        guard case .string(let s) = value, s.hasPrefix("#"), let v = UInt64(s.dropFirst(), radix: 16) else { return .white }
        if s.count == 9 { return Color(.sRGB, red: Double((v >> 24) & 255) / 255, green: Double((v >> 16) & 255) / 255, blue: Double((v >> 8) & 255) / 255, opacity: Double(v & 255) / 255) }
        return Color(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    static func hex(from color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func b(_ x: CGFloat) -> Int { Int((x * 255).rounded()) }
        let base = String(format: "#%02x%02x%02x", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
        return c.alphaComponent >= 0.999 ? base : base + String(format: "%02x", b(c.alphaComponent))
    }
}
