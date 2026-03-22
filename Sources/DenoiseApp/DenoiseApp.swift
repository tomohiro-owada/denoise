import SwiftUI
import CoreAudio
import DenoiseCore

@main
struct DenoiseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window — menu bar only
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let processor = AudioProcessor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Load saved settings
        let settings = DenoiseSettings.load()
        settings.apply(to: processor)

        // Setup menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.badge.plus", accessibilityDescription: "Denoise")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(processor: processor)
        )

        // Auto-start if configured
        if settings.autoStart {
            startProcessing(inputDeviceUID: settings.inputDeviceUID)
        }

        // Start IPC listener for CLI
        IPCServer.shared.start(processor: processor)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func startProcessing(inputDeviceUID: String?) {
        let devices = VirtualDeviceInstaller.findInputDevices()
        var deviceID: AudioDeviceID?
        if let uid = inputDeviceUID {
            deviceID = devices.first(where: { $0.uid == uid })?.id
        }
        try? processor.start(inputDeviceID: deviceID)
    }
}
