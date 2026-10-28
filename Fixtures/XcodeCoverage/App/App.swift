// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#if canImport(UIKit)
import UIKit

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    @objc func showSharing() { showScreen(sharingTitle()) }
    @objc func showNotes() { showScreen(notesTitle()) }
    func showScreen(_ title: String) {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel(frame: CGRect(x: 30, y: 120, width: 300, height: 50))
        label.text = title
        label.accessibilityIdentifier = "screenTitle"
        controller.view.addSubview(label)
        window?.rootViewController = controller
    }
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel(frame: CGRect(x: 30, y: 120, width: 300, height: 50))
        label.text = "Hello, checkout"
        label.accessibilityIdentifier = "welcome"
        controller.view.addSubview(label)
        for (index, title, action) in [(0, "Sharing", #selector(showSharing)), (1, "Notes", #selector(showNotes))] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = title.lowercased() + "Button"
            button.frame = CGRect(x: 30, y: 200 + index * 60, width: 280, height: 50)
            button.addTarget(self, action: action, for: .touchUpInside)
            controller.view.addSubview(button)
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
        return true
    }
}
#else
import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func showSharing() { showScreen(sharingTitle()) }
    @objc func showNotes() { showScreen(notesTitle()) }
    func showScreen(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.setAccessibilityIdentifier("screenTitle")
        label.frame = NSRect(x: 30, y: 80, width: 300, height: 30)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView!.addSubview(label)
    }
    var window: NSWindow!
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Impact Demo"
        let label = NSTextField(labelWithString: "Hello, checkout")
        label.setAccessibilityIdentifier("welcome")
        label.frame = NSRect(x: 30, y: 80, width: 300, height: 30)
        window.contentView!.addSubview(label)
        for (index, title, action) in [(0, "Sharing", #selector(showSharing)), (1, "Notes", #selector(showNotes))] {
            let button = NSButton(title: title, target: self, action: action)
            button.setAccessibilityIdentifier(title.lowercased() + "Button")
            button.frame = NSRect(x: 30 + index * 160, y: 20, width: 150, height: 40)
            window.contentView!.addSubview(button)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

#endif
