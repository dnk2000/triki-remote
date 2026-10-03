import AppKit
import UserNotifications

@main
final class App: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var bluetooth: TrikiBluetoothManager!
    private var musicModeItem: NSMenuItem!
    private var workModeItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var modeSelector: NSSegmentedControl!
    private var modeDescription: NSTextField!
    private var reverseCheckbox: NSButton!
    private var testButton: NSButton!
    private var copyLinkCheckbox: NSButton!
    private lazy var meetings = MeetingController(onCopied: { [weak self] in
        self?.postNotification(identifier: "triki-meet-copied", title: "Google Meet link copied",
                               body: "The meeting link is in your clipboard. Paste it with ⌘V.")
    }, onError: { [weak self] message in
        NSLog("Google Meet: %@", message)
        self?.postNotification(identifier: "triki-meet-error", title: "Google Meet needs attention", body: message)
    })
    private var copyMeetLink: Bool { UserDefaults.standard.bool(forKey: "copyMeetLink") }

    static func main() {
        let application = NSApplication.shared
        let delegate = App()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["copyMeetLink": true])
        if !defaults.bool(forKey: "migratedMediaButtonSettings") {
            let previous = defaults.persistentDomain(forName: "com.triki.media-button") ?? [:]
            for key in ["controlMode", "reverseVolumeRotation"] where defaults.object(forKey: key) == nil {
                if let value = previous[key] { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "migratedMediaButtonSettings")
        }
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
           }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "TrikiRemote", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        let status = NSMenuItem(title: "Starting Bluetooth…", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())
        musicModeItem = NSMenuItem(title: "Media mode", action: #selector(selectMenuMode(_:)), keyEquivalent: "")
        musicModeItem.target = self
        musicModeItem.representedObject = ControlMode.music.rawValue
        menu.addItem(musicModeItem)
        workModeItem = NSMenuItem(title: "Work mode", action: #selector(selectMenuMode(_:)), keyEquivalent: "")
        workModeItem.target = self
        workModeItem.representedObject = ControlMode.work.rawValue
        menu.addItem(workModeItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let permission = NSMenuItem(title: "Enable Accessibility…", action: #selector(requestPermission), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        menu.addItem(.separator())
        // Use our own action so macOS does not decorate the standard terminate action.
        let quit = NSMenuItem(title: "Quit Triki Remote", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.image = nil
        menu.addItem(quit)
        statusItem.menu = menu
        bluetooth = TrikiBluetoothManager(status: { text in status.title = text },
                                          onWorkPress: { [weak self] in self?.createMeeting() },
                                          onDoublePress: { [weak self] in self?.toggleModeFromButton() })
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Notifications: %@", error.localizedDescription) }
            if !granted { NSLog("Enable notifications for Triki Remote to see mode-switch banners") }
        }
        if bluetooth.mode == .music { MediaKeyController.requestPermission() }
        refreshMode()
    }

    @objc private func showSettings() {
        if settingsWindow == nil { createSettingsWindow() }
        refreshMode()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func createSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Triki Remote Settings"
        window.isReleasedWhenClosed = false
        window.center()

        let title = NSTextField(labelWithString: "Choose your mode")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Changes apply immediately and are saved automatically.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        modeSelector = NSSegmentedControl(labels: ["Media mode", "Work mode"], trackingMode: .selectOne,
                                           target: self, action: #selector(changeMode))
        modeSelector.controlSize = .large
        modeSelector.setWidth(188, forSegment: 0)
        modeSelector.setWidth(188, forSegment: 1)
        modeDescription = NSTextField(wrappingLabelWithString: "")
        modeDescription.font = .systemFont(ofSize: 14)
        modeDescription.heightAnchor.constraint(equalToConstant: 58).isActive = true
        reverseCheckbox = NSButton(checkboxWithTitle: "Reverse volume rotation", target: self,
                                   action: #selector(reverseRotation(_:)))
        testButton = NSButton(title: "Test Play/Pause", target: self, action: #selector(testPlayPause))
        testButton.bezelStyle = .rounded
        copyLinkCheckbox = NSButton(checkboxWithTitle: "Copy Meet link to clipboard", target: self,
                                    action: #selector(changeCopyLink(_:)))
        let stack = NSStackView(views: [title, subtitle, modeSelector, modeDescription, reverseCheckbox, testButton, copyLinkCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(6, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            modeDescription.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        settingsWindow = window
    }

    private func refreshMode() {
        let music = bluetooth.mode == .music
        musicModeItem.state = music ? .on : .off
        workModeItem.state = music ? .off : .on
        statusItem.button?.image = NSImage(systemSymbolName: music ? "playpause.circle" : "briefcase",
                                           accessibilityDescription: "Triki Remote — \(bluetooth.mode.title)")
        statusItem.button?.toolTip = "Triki Remote — \(bluetooth.mode.title)"
        guard settingsWindow != nil else { return }
        modeSelector.selectedSegment = music ? 0 : 1
        modeDescription.stringValue = music
            ? "Press the button to play or pause. Rotate TRIKI to change system volume."
            : "Press to create a Google Meet in Chrome\(copyMeetLink ? " and copy its link" : ""). Sign in to Google first. Rotation has no action."
        reverseCheckbox.state = UserDefaults.standard.bool(forKey: "reverseVolumeRotation") ? .on : .off
        reverseCheckbox.isHidden = !music
        testButton.isHidden = !music
        copyLinkCheckbox.isHidden = music
        copyLinkCheckbox.state = copyMeetLink ? .on : .off
    }

    @objc private func changeCopyLink(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "copyMeetLink")
        if !copyMeetLink {
            meetings.cancel()
        }
        refreshMode()
    }

    @objc private func changeMode() {
        setMode(modeSelector.selectedSegment == 0 ? .music : .work)
    }

    @objc private func selectMenuMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ControlMode(rawValue: raw) else { return }
        setMode(mode)
    }

    private func setMode(_ mode: ControlMode) {
        bluetooth.setMode(mode)
        refreshMode()
        if mode == .music { MediaKeyController.requestPermission() }
    }

    private func toggleModeFromButton() {
        setMode(bluetooth.mode == .music ? .work : .music)
        postNotification(identifier: "triki-mode", title: bluetooth.mode.title,
                         body: bluetooth.mode == .music
                            ? "Button: Play/Pause · Rotation: Volume"
                            : "Button: Create Google Meet\(copyMeetLink ? " and copy link" : "")")
    }

    private func postNotification(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Notification failed: %@", error.localizedDescription) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func createMeeting() {
        meetings.create(copyLink: copyMeetLink)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        meetings.cancel()
        bluetooth?.stop()
    }

    @objc private func testPlayPause() {
        guard bluetooth.mode == .music else { return }
        MediaKeyController.playPause()
    }

    @objc private func reverseRotation(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "reverseVolumeRotation")
    }

    @objc private func requestPermission() {
        MediaKeyController.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
