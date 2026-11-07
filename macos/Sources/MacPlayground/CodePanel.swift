import AppKit
import HokusaiRecipes
import PlaygroundModel
import SwiftUI

struct CodePanel: View {
    @Environment(Playground.self) private var playground
    @State private var target: SwiftCodeGenerator.Target = .core

    var body: some View {
        let code = playground.swiftCode(target: target)
        VStack(spacing: 0) {
            HStack {
                Text("Swift").font(.headline)
                Picker("Target", selection: $target) {
                    Text("Core").tag(SwiftCodeGenerator.Target.core)
                    Text("Vapor").tag(SwiftCodeGenerator.Target.vapor)
                    Text("Hummingbird").tag(SwiftCodeGenerator.Target.hummingbird)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            ScrollView([.horizontal, .vertical]) {
                Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .background(.bar)
    }
}
