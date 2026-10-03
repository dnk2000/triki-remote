import AppKit

/// All state and callbacks are confined to the main queue. Chrome automation
/// runs in Apple's osascript process so an unresponsive browser cannot block BLE.
final class MeetingController {
    private let onCopied: () -> Void
    private let onError: (String) -> Void
    private var requestID = UUID()
    private var poll: DispatchWorkItem?
    private var scriptTimeout: DispatchWorkItem?
    private var process: Process?

    init(onCopied: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.onCopied = onCopied
        self.onError = onError
    }

    func cancel() {
        requestID = UUID()
        poll?.cancel()
        poll = nil
        scriptTimeout?.cancel()
        scriptTimeout = nil
        let running = process
        process = nil
        if let running, running.isRunning { running.terminate() }
    }

    func create(copyLink: Bool) {
        cancel()
        let request = requestID
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let newMeeting = URL(string: "https://meet.google.com/new") else {
            onError("Install Google Chrome to create meetings from Work mode.")
            return
        }
        if !copyLink {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([newMeeting], withApplicationAt: chrome, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self, self.requestID == request, let error else { return }
                    self.onError(error.localizedDescription)
                }
            }
            return
        }
        runScript(Self.createScript, timeout: 60) { [weak self] result in
            guard let self, self.requestID == request else { return }
            switch result {
            case .failure(let error): self.onError(error.localizedDescription)
            case .success(let value):
                guard let tabID = Int(value), tabID > 0 else {
                    self.onError("Chrome did not return a valid meeting tab. Please try again.")
                    return
                }
                self.readMeeting(tabID: tabID, request: request,
                                 deadline: ProcessInfo.processInfo.systemUptime + 90)
            }
        }
    }

    private func readMeeting(tabID: Int, request: UUID, deadline: Double) {
        guard requestID == request else { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            onError("The meeting link is not ready. Sign in to Google in Chrome, then try again. Your clipboard was not changed.")
            return
        }
        runScript(Self.readScript(tabID: tabID), timeout: 10) { [weak self] result in
            guard let self, self.requestID == request else { return }
            switch result {
            case .failure(let error): self.onError(error.localizedDescription)
            case .success(let address):
                if address.isEmpty {
                    self.onError("The Meet tab was closed before its link could be copied.")
                } else if let link = Self.shareableURL(address) {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(link, forType: .string) {
                        NSLog("Google Meet link copied to clipboard")
                        self.onCopied()
                    } else {
                        self.onError("The meeting opened, but its link could not be copied.")
                    }
                } else {
                    let work = DispatchWorkItem { [weak self] in
                        self?.readMeeting(tabID: tabID, request: request, deadline: deadline)
                    }
                    self.poll = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
                }
            }
        }
    }

    static func shareableURL(_ address: String) -> String? {
        guard let url = URL(string: address), url.scheme == "https", url.host == "meet.google.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}/?$", options: .regularExpression) != nil else { return nil }
        return "https://meet.google.com/" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static let createScript = """
        tell application id "com.google.Chrome"
            activate
            if (count of windows) is 0 then make new window
            tell front window
                set meetingTab to make new tab with properties {URL:"https://meet.google.com/new"}
                set active tab index to (count of tabs)
                return (id of meetingTab) as text
            end tell
        end tell
        """

    static func readScript(tabID: Int) -> String {
        """
        if application id "com.google.Chrome" is not running then return ""
        tell application id "com.google.Chrome"
            repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                    if ((id of browserTab) as text) is "\(tabID)" then return URL of browserTab
                end repeat
            end repeat
        end tell
        return ""
        """
    }

    // Temporary files avoid pipe-buffer deadlocks for unexpectedly long Chrome
    // errors/URLs. Each invocation owns its output; cancelled jobs cannot deliver.
    func runScript(_ source: String, timeout: TimeInterval,
                           completion: @escaping (Result<String, Error>) -> Void) {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("triki-script-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            completion(.failure(Self.error("Could not prepare Chrome automation output.")))
            return
        }
        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        job.arguments = ["-e", source]
        job.standardOutput = output
        job.standardError = output
        job.standardInput = FileHandle.nullDevice
        job.terminationHandler = { [weak self] finished in
            let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: outputURL)
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.scriptTimeout?.cancel()
                self.scriptTimeout = nil
                if finished.terminationStatus == 0 {
                    completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    let message = text.contains("-1743")
                        ? "Allow Triki Remote to control Google Chrome in System Settings → Privacy & Security → Automation, then try again."
                        : "Chrome automation failed. \(text.prefix(500))"
                    completion(.failure(Self.error(message)))
                }
            }
        }
        do {
            process = job
            try job.run()
            try? output.close()
            let work = DispatchWorkItem { [weak self, weak job] in
                guard let self, let job, self.process === job else { return }
                self.process = nil
                if job.isRunning { job.terminate() }
                completion(.failure(Self.error("Chrome did not respond in time. Check its permission dialogs and try again.")))
            }
            scriptTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        } catch {
            process = nil
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
            completion(.failure(error))
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "TrikiRemote.Meet", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
