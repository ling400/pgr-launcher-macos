import SwiftUI
import AppKit

/// Applies the launcher's preferred window geometry once the SwiftUI window exists.
/// Kept in the UI layer so `main.swift` stays untouched.
struct WindowConfigurator: NSViewRepresentable {
    var targetSize: CGSize = CGSize(width: 1080, height: 680)
    var minimumSize: CGSize = CGSize(width: 1080, height: 680)

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setContentSize(targetSize)
            window.minSize = minimumSize
            window.center()
            window.title = "战双启动器"
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
