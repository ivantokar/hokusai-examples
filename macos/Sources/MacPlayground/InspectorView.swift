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
                        ParamControl(spec: p, value: step.params[p.name]) { playground.setParam(step: step.id, p, to: $0) }
                    }
                    let advanced = spec.params.filter(\.advanced)
                    if !advanced.isEmpty {
                        DisclosureGroup("Advanced") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(advanced, id: \.name) { p in
                                    ParamControl(spec: p, value: step.params[p.name]) { playground.setParam(step: step.id, p, to: $0) }
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

/// One control, generated from the catalog's description of a parameter.
struct ParamControl: View {
    let spec: ParamSpec
    let value: ParamValue?
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
            case .text:
                Text(spec.label).fontWeight(.medium)
                TextField(spec.label, text: Binding(get: { if case .string(let s) = current { s } else { "" } }, set: { set(.string($0)) }))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            if let help = spec.help { Text(help).font(.caption).foregroundStyle(.secondary) }
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
