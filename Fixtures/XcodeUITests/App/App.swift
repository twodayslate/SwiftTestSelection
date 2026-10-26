// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#if canImport(UIKit)
import UIKit

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel(frame: CGRect(x: 30, y: 120, width: 300, height: 50))
        label.text = "Hello, checkout"
        label.accessibilityIdentifier = "welcome"
        controller.view.addSubview(label)
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
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

#endif
