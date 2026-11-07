import Foundation

/// The same generated sample images the Web demo uses, bundled with the app.
enum Samples {
    struct Sample: Identifiable { let file: String; let title: String; var id: String { file } }
    static let all = [
        Sample(file: "scene.png", title: "Scene (landscape)"),
        Sample(file: "phone.jpg", title: "Phone photo (EXIF rotated)"),
        Sample(file: "emblem.png", title: "Emblem (transparent)"),
    ]
    static func data(_ file: String) -> Data? {
        Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "fixtures").flatMap { try? Data(contentsOf: $0) }
    }
}
