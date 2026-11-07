import HokusaiRecipes
import PlaygroundModel
import SwiftUI

struct PipelineView: View {
    @Environment(Playground.self) private var playground
    private let specs = Dictionary(uniqueKeysWithValues: Catalog.operations.map { ($0.id, $0) })

    var body: some View {
        @Bindable var playground = playground
        List(selection: $playground.selection) {
            Section("Pipeline") {
                if playground.recipe.steps.isEmpty { Text("Add an operation to start.").foregroundStyle(.secondary) }
                ForEach(Array(playground.recipe.steps.enumerated()), id: \.element.id) { index, step in
                    let title = specs[step.op]?.title ?? step.op
                    HStack {
                        Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 20, alignment: .trailing)
                        Text(title).strikethrough(!step.enabled).foregroundStyle(step.enabled ? .primary : .secondary)
                        Spacer()
                    }
                    .tag(step.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(index + 1): \(title)\(step.enabled ? "" : ", disabled")")
                    .contextMenu {
                        Button(step.enabled ? "Disable" : "Enable") { playground.toggleStep(step.id) }
                        Button("Duplicate") { playground.duplicateStep(step.id) }
                        Button("Move up") { playground.moveStep(step.id, by: -1) }.disabled(index == 0)
                        Button("Move down") { playground.moveStep(step.id, by: 1) }.disabled(index == playground.recipe.steps.count - 1)
                        Divider()
                        Button("Remove", role: .destructive) { playground.removeStep(step.id) }
                    }
                }
                .onMove { playground.move(from: $0, to: $1) }
                .onDelete { offsets in for i in offsets { playground.removeStep(playground.recipe.steps[i].id) } }
            }
            Section("Output") {
                Picker("Format", selection: Binding(get: { playground.recipe.output.format }, set: { playground.setFormat($0) })) {
                    ForEach(Catalog.outputs, id: \.format) { Text($0.title).tag($0.format) }
                }
                ForEach(Catalog.outputs.first { $0.format == playground.recipe.output.format }?.params ?? [], id: \.name) { spec in
                    ParamControl(spec: spec, value: playground.recipe.output.options[spec.name]) { playground.setOutputParam(spec, to: $0) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    ForEach(OperationGroup.allCases, id: \.self) { group in
                        Section(group.rawValue.capitalized) {
                            ForEach(Catalog.operations.filter { $0.group == group }, id: \.id) { spec in
                                Button(spec.title) { playground.addStep(spec.id) }
                            }
                        }
                    }
                } label: { Label("Add operation", systemImage: "plus") }
                Spacer()
                Button("Move up", systemImage: "arrow.up") { if let s = playground.selection { playground.moveStep(s, by: -1) } }.labelStyle(.iconOnly).disabled(playground.selection == nil)
                Button("Move down", systemImage: "arrow.down") { if let s = playground.selection { playground.moveStep(s, by: 1) } }.labelStyle(.iconOnly).disabled(playground.selection == nil)
                Button("Remove", systemImage: "trash") { if let s = playground.selection { playground.removeStep(s) } }.labelStyle(.iconOnly).disabled(playground.selection == nil)
            }
            .padding(8).background(.bar)
        }
        .onDeleteCommand { if let s = playground.selection { playground.removeStep(s) } }
    }
}
