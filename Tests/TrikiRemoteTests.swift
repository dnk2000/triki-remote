import AppKit

@main
enum TrikiRemoteTests {
    static func packet(_ state: UInt8) -> Data {
        Data([0x22, state] + Array(repeating: UInt8(0), count: 12))
    }

    static func main() {
        precondition(MeetingController.shareableURL("https://meet.google.com/abc-defg-hij?authuser=1#test") == "https://meet.google.com/abc-defg-hij")
        precondition(MeetingController.shareableURL("https://meet.google.com/abc-defg-hij/") == "https://meet.google.com/abc-defg-hij")
        for address in ["", "https://meet.google.com/new", "https://accounts.google.com/abc-defg-hij",
                        "https://meet.google.com.evil.example/abc-defg-hij", "http://meet.google.com/abc-defg-hij",
                        "https://meet.google.com/abc-defg-hij/extra", "https://user@meet.google.com/abc-defg-hij",
                        "https://meet.google.com:444/abc-defg-hij", "https://meet.google.com/abc-def-hij"] {
            precondition(MeetingController.shareableURL(address) == nil, "Only canonical meeting links may be copied")
        }
        let automation = MeetingController(onCopied: {}, onError: { fatalError($0) })
        func waitFor(_ ready: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !ready(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(ready(), "Automation completion timed out")
        }
        var completed = false
        automation.runScript("return \"test output\"", timeout: 3) { result in
            precondition(try! result.get() == "test output")
            completed = true
        }
        waitFor { completed }
        completed = false
        automation.runScript("error \"expected failure\" number 42", timeout: 3) { result in
            guard case .failure = result else { fatalError("Script failure was ignored") }
            completed = true
        }
        waitFor { completed }
        completed = false
        var mainQueueResponsive = false
        automation.runScript("repeat\nend repeat", timeout: 0.1) { result in
            guard case .failure = result else { fatalError("Unresponsive script was not stopped") }
            completed = true
        }
        DispatchQueue.main.async { mainQueueResponsive = true }
        waitFor { completed }
        precondition(mainQueueResponsive, "Automation must not block the main queue")
        var cancelledDelivered = false
        automation.runScript("repeat\nend repeat", timeout: 3) { _ in cancelledDelivered = true }
        automation.cancel()
        completed = false
        automation.runScript("return \"replacement\"", timeout: 3) { result in
            precondition(try! result.get() == "replacement")
            completed = true
        }
        waitFor { completed }
        precondition(!cancelledDelivered, "Cancelled work must not deliver stale results")
        automation.cancel()
        print("PASS: Meet URL validation, script execution/errors/timeout, UI responsiveness, cancellation")
        var clicks = PressGestureDetector()
        precondition(clicks.press(at: 0).isEmpty)
        precondition(clicks.expire(at: 0.2) == nil)
        precondition(clicks.press(at: 0.25) == [.double])
        precondition(clicks.expire(at: 1) == nil, "Double click must suppress the single action")
        precondition(clicks.press(at: 2).isEmpty)
        precondition(clicks.expire(at: 2.36) == .single)
        precondition(clicks.expire(at: 3) == nil, "Holding cannot repeat the single action")
        precondition(clicks.press(at: 4).isEmpty)
        precondition(clicks.press(at: 4.4) == [.single], "Delayed timer must not turn slow presses into a double")
        precondition(clicks.expire(at: 4.76) == .single)
        precondition(clicks.press(at: 5).isEmpty)
        clicks.cancel()
        precondition(clicks.expire(at: 6) == nil, "Disconnect or manual mode change cancels pending actions")
        precondition(clicks.press(at: 7).isEmpty)
        precondition(clicks.press(at: 7.1) == [.double])
        precondition(clicks.press(at: 7.2).isEmpty)
        precondition(clicks.expire(at: 7.56) == .single, "Triple click is a double then a single")
        var heldParser = ButtonStateParser()
        var heldClicks = PressGestureDetector()
        for i in 0..<100 {
            if heldParser.consume(packet(1)) == .pressed {
                precondition(heldClicks.press(at: Double(i) / 100).isEmpty)
            }
        }
        precondition(heldClicks.expire(at: 1) == .single)
        print("PASS: single/double/triple presses, no duplicate actions, held button, cancellation, delayed timer")
        func motion(_ gyro: [Int16], _ acceleration: [Int16] = [0, 0, 2050]) -> Data {
            var data = Data([0x22, 0])
            for value in gyro + acceleration {
                let bits = UInt16(bitPattern: value)
                data.append(UInt8(truncatingIfNeeded: bits))
                data.append(UInt8(truncatingIfNeeded: bits >> 8))
            }
            return data
        }
        var rotation = RotationVolumeController()
        for i in 0..<100 {
            precondition(rotation.consume(motion([20, -30, 200]), at: Double(i) / 53) == nil)
        }
        precondition(rotation.consume(motion([0, 0, -1500]), at: 2) == nil)
        precondition(rotation.consume(motion([0, 0, -1500]), at: 2.02) == .volumeUp)
        for _ in 0..<100 {
            precondition(rotation.consume(motion([0, 0, -1500]), at: 2.02) == nil, "Burst cannot raise volume repeatedly")
        }
        precondition(rotation.consume(motion([0, 0, -1500]), at: 2.22) == .volumeUp)
        precondition(rotation.consume(motion([0, 0, 1500]), at: 2.42) == nil)
        precondition(rotation.consume(motion([0, 0, 1500]), at: 2.44) == .volumeDown)
        precondition(rotation.consume(motion([0, 0, 0]), at: 2.64) == nil)
        precondition(rotation.consume(motion([2500, 0, 100]), at: 2.66) == nil, "Tilt must not change volume")
        precondition(rotation.consume(motion([0, 0, 1500]), at: 4) == nil, "Gap requires fresh confirmation")
        precondition(rotation.consume(motion([0, 0, 1500]), at: 4.02, reversed: true) == .volumeUp)
        var flipped = RotationVolumeController()
        precondition(flipped.consume(motion([0, 0, 1500], [0, 0, -2050]), at: 0) == nil)
        precondition(flipped.consume(motion([0, 0, 1500], [0, 0, -2050]), at: 0.02) == .volumeUp)
        for key in [MediaKeyController.Key.volumeUp, .volumeDown] {
            for down in [true, false] {
                let event = NSEvent(cgEvent: MediaKeyController.makeEvent(isDown: down, key: key)!)!
                precondition(event.data1 == (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            }
        }
        print("PASS: rotation directions, jitter/tilt rejection, burst rate limit, gaps, inversion, volume events")
        var parser = ButtonStateParser()
        let events = [0, 1, 1, 1, 0, 1].compactMap { parser.consume(packet(UInt8($0))) }
        precondition(events == [.released, .pressed, .released, .pressed], "Example must trigger twice")
        for _ in 0..<10_000 {
            precondition(parser.consume(packet(1)) == nil, "Holding must never repeat")
        }
        // Malformed notifications must not change the remembered pressed state.
        let invalid = [Data(), Data([0x22, 0]), Data(repeating: 0, count: 14),
                       packet(2), packet(15), packet(255), packet(0) + Data([0])]
        for data in invalid {
            precondition(parser.consume(data) == nil)
            precondition(parser.previousButtonState)
        }
        // The manager preserves this parser through disconnects and power changes.
        precondition(parser.consume(packet(1)) == nil, "Held button after reconnect must not repeat")
        precondition(parser.consume(packet(0)) == .released)
        precondition(parser.consume(packet(0)) == nil)
        precondition(parser.consume(packet(1)) == .pressed)
        var fresh = ButtonStateParser()
        precondition(fresh.consume(packet(1)) == .pressed, "Initial previous state is false")

        let frames = [0, 1, 1, 1, 0, 1].reduce(into: Data()) { $0.append(packet(UInt8($1))) }
        for chunkSize in 1...frames.count {
            var stream = ButtonStreamParser()
            var result: [ButtonStateParser.Transition] = []
            for start in stride(from: 0, to: frames.count, by: chunkSize) {
                result += stream.consume(frames.subdata(in: start..<min(start + chunkSize, frames.count)))
            }
            precondition(result == events, "Chunk boundaries must not affect button events")
        }
        var stream = ButtonStreamParser()
        precondition(stream.consume(Data([0x21, 0, 0, 0, 0]) + packet(0) + packet(1)) == [.released, .pressed])
        precondition(stream.consume(Data(packet(0).prefix(7))).isEmpty)
        stream.discardPartialFrame()
        precondition(stream.consume(packet(1)).isEmpty, "Discard partial frames but retain held state")
        precondition(stream.consume(packet(0) + packet(1)) == [.released, .pressed])
        var unsupported = packet(2)
        unsupported[4] = 0x22
        unsupported[5] = 0
        precondition(stream.consume(unsupported + packet(1)).isEmpty, "Do not interpret payload as a button header")

        if CommandLine.arguments.count > 1 {
            let log = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            var replay = ButtonStreamParser()
            var recorded: [ButtonStateParser.Transition] = []
            var notifications = 0
            for line in log.components(separatedBy: .newlines) where line.contains("RAW TX [") {
                guard let range = line.range(of: "]: ", options: .backwards) else { continue }
                let bytes = line[range.upperBound...].split(separator: " ").map { UInt8($0, radix: 16)! }
                recorded += replay.consume(Data(bytes))
                notifications += 1
            }
            precondition(notifications > 0, "Capture contains no notifications")
            precondition(recorded == [.released, .pressed, .released, .pressed, .released], "Recorded two presses must replay exactly")
            print("PASS: hardware capture replay (\(notifications) notifications, exactly two presses)")
        }

        // Inspect events without posting or changing the user's media playback.
        for isDown in [true, false] {
            guard let cgEvent = MediaKeyController.makeEvent(isDown: isDown),
                  let event = NSEvent(cgEvent: cgEvent) else { fatalError("Missing media event") }
            precondition(event.type == .systemDefined && event.subtype.rawValue == 8)
            precondition(event.data1 == (16 << 16) | ((isDown ? 0xA : 0xB) << 8))
            precondition(event.data1 & 1 == 0, "Repeat flag must be clear")
            precondition(event.data2 == -1)
        }
        print("PASS: button edges, 10,000 held packets, malformed packets, all chunk sizes, reconnect state, media-key encoding")
    }
}
