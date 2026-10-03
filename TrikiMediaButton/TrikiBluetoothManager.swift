import CoreBluetooth

enum ControlMode: String {
    case music, work

    var title: String { self == .music ? "Media mode" : "Work mode" }
}

struct PressGestureDetector {
    enum Action: Equatable { case single, double }
    static let interval = 0.35
    private(set) var deadline: Double?

    mutating func press(at time: Double) -> [Action] {
        if let deadline, time < deadline {
            self.deadline = nil
            return [.double]
        }
        let expired: [Action] = deadline == nil ? [] : [.single]
        deadline = time + Self.interval
        return expired
    }

    mutating func expire(at time: Double) -> Action? {
        guard let deadline, time >= deadline else { return nil }
        self.deadline = nil
        return .single
    }

    mutating func cancel() { deadline = nil }
}

// CAP001 captures confirm byte 1 is 0 when released and 1 when pressed.
struct ButtonStateParser {
    enum Transition: Equatable { case pressed, released }
    private(set) var previousButtonState = false
    private var receivedPacket = false

    mutating func consume(_ data: Data) -> Transition? {
        guard data.count == 14 else { return nil }
        let bytes = Array(data)
        guard bytes[0] == 0x22, bytes[1] == 0 || bytes[1] == 1 else { return nil }
        let currentButtonState = bytes[1] == 1
        let risingEdge = !previousButtonState && currentButtonState
        let reportRelease = !currentButtonState && (!receivedPacket || previousButtonState)
        previousButtonState = currentButtonState
        receivedPacket = true
        if risingEdge { return .pressed }
        return reportRelease ? .released : nil
    }
}

// UART notifications are chunks of a byte stream, not individual IMU frames.
struct ButtonStreamParser {
    private var buffer: [UInt8] = []
    private var button = ButtonStateParser()

    mutating func consume(_ data: Data, onFrame: (Data) -> Void = { _ in }) -> [ButtonStateParser.Transition] {
        buffer.append(contentsOf: data)
        var transitions: [ButtonStateParser.Transition] = []
        var offset = 0
        while buffer.count - offset >= 2 {
            // Frame IDs 0...15 are used by the reference protocol. Consume
            // unsupported states as whole frames, never scan their IMU payload.
            guard buffer[offset] == 0x22, buffer[offset + 1] <= 0x0F else {
                offset += 1
                continue
            }
            guard buffer.count - offset >= 14 else { break }
            let frame = Data(buffer[offset..<(offset + 14)])
            onFrame(frame)
            if let transition = button.consume(frame) {
                transitions.append(transition)
            }
            offset += 14
        }
        buffer.removeFirst(offset)
        return transitions
    }

    mutating func discardPartialFrame() {
        buffer.removeAll(keepingCapacity: true)
        // Keep button state: reconnecting with a held button must not retrigger.
    }
}

// Detect sustained rotation about vertical, rejecting tilt and small hand jitter.
// Raw units avoid assuming an undocumented gyro scale. Timers use arrival time
// so a burst of buffered BLE frames cannot produce a burst of volume events.
struct RotationVolumeController {
    private var direction = 0
    private var consecutiveSamples = 0
    private var lastStep = -Double.infinity
    private var lastSample: Double?

    mutating func consume(_ frame: Data, at time: Double, reversed: Bool = false) -> MediaKeyController.Key? {
        guard frame.count == 14 else { return nil }
        let bytes = Array(frame)
        guard bytes[0] == 0x22, bytes[1] <= 1 else { return nil }
        let values = stride(from: 2, to: 14, by: 2).map {
            Double(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8))
        }
        if let lastSample, time - lastSample > 0.5 {
            direction = 0
            consecutiveSamples = 0
        }
        lastSample = time
        let gravity = sqrt(values[3] * values[3] + values[4] * values[4] + values[5] * values[5])
        let spin = sqrt(values[0] * values[0] + values[1] * values[1] + values[2] * values[2])
        guard gravity > 1200, gravity < 3000 else {
            direction = 0
            consecutiveSamples = 0
            return nil
        }
        let rotation = (values[0] * values[3] + values[1] * values[4] + values[2] * values[5]) / gravity
        let threshold = direction == 0 ? 1000.0 : 650.0
        guard abs(rotation) >= threshold, abs(rotation) >= spin * 0.75 else {
            direction = 0
            consecutiveSamples = 0
            return nil
        }
        let nextDirection = rotation < 0 ? 1 : -1
        if nextDirection != direction {
            guard abs(rotation) >= 1000 else { return nil }
            direction = nextDirection
            consecutiveSamples = 0
        }
        consecutiveSamples = min(consecutiveSamples + 1, 2)
        guard consecutiveSamples >= 2, time - lastStep >= 0.18 else { return nil }
        lastStep = time
        return (direction == 1) != reversed ? .volumeUp : .volumeDown
    }
}

final class TrikiBluetoothManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private(set) var mode = ControlMode(rawValue: UserDefaults.standard.string(forKey: "controlMode") ?? "") ?? .music

    func setMode(_ mode: ControlMode) {
        cancelPendingPress()
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "controlMode")
        rotation = RotationVolumeController()
        NSLog("%@ enabled", mode.title)
    }

    private static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let startCommand = Data([0x20, 0x10, 0x00, 0xD0, 0x07, 0x34, 0x00, 0x03])

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var streamStarted = false
    private var retry: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var notificationCheck: DispatchWorkItem?
    private var receivedIMU = false
    private var retryDelay: Double = 2
    private var stopped = false
    // Preserve state across reconnects so a held button does not trigger again.
    private var parser = ButtonStreamParser()
    private var rotation = RotationVolumeController()
    private let status: (String) -> Void
    private let onWorkPress: () -> Void
    private let onDoublePress: () -> Void
    private var pressGesture = PressGestureDetector()
    private var pendingPress: DispatchWorkItem?

    init(status: @escaping (String) -> Void, onWorkPress: @escaping () -> Void,
         onDoublePress: @escaping () -> Void) {
        self.status = status
        self.onWorkPress = onWorkPress
        self.onDoublePress = onDoublePress
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped else { return }
        retry?.cancel()
        timeout?.cancel()
        if peripheral != nil { NSLog("TRIKI disconnected: Bluetooth state changed") }
        clearConnection()
        switch central.state {
        case .poweredOn: scan()
        case .poweredOff: status("Bluetooth is off")
        case .unauthorized: status("Allow Bluetooth in System Settings")
        case .unsupported: status("Bluetooth is unavailable")
        default: status("Waiting for Bluetooth…")
        }
    }

    private func scan() {
        guard !stopped, central.state == .poweredOn, peripheral == nil else { return }
        status("Searching for TRIKI…")
        // Some caps advertise only a name; verify NUS after connecting.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "").lowercased()
        guard name.hasPrefix("triki") || name.hasPrefix("cap001") else { return }
        NSLog("TRIKI discovered: %@", name)
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status("Connecting to TRIKI…")
        central.connect(peripheral)
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral, self.peripheral === peripheral else { return }
            self.fail("Connection/setup timed out")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        NSLog("TRIKI connected")
        status("Preparing TRIKI…")
        peripheral.discoverServices([Self.service])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            fail("NUS service unavailable: \(error?.localizedDescription ?? "missing service")")
            return
        }
        peripheral.discoverCharacteristics([Self.rx, Self.tx], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        rx = service.characteristics?.first(where: { $0.uuid == Self.rx })
        tx = service.characteristics?.first(where: { $0.uuid == Self.tx })
        guard error == nil, let rx, let tx,
              rx.properties.contains(.writeWithoutResponse), tx.properties.contains(.notify) else {
            fail("Required UART characteristics unavailable")
            return
        }
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == Self.tx else { return }
        guard error == nil, characteristic.isNotifying else {
            fail("IMU notification subscription failed")
            return
        }
        startStreamIfReady()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        startStreamIfReady()
    }

    private func startStreamIfReady() {
        guard !streamStarted, let peripheral, let rx, tx?.isNotifying == true,
              peripheral.canSendWriteWithoutResponse else { return }
        peripheral.writeValue(Self.startCommand, for: rx, type: .withoutResponse)
        streamStarted = true
        status("Waiting for TRIKI data…")
        NSLog("IMU notifications enabled; start command sent")
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.streamStarted, !self.receivedIMU else { return }
            self.fail("No valid IMU frames received after initialization")
        }
        notificationCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: check)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == Self.tx else { return }
        if let error {
            fail("IMU notification error: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        var frames: [Data] = []
        let transitions = parser.consume(data) { frames.append($0) }
        if !receivedIMU, frames.contains(where: { $0.count == 14 && $0[$0.startIndex + 1] <= 1 }) {
            receivedIMU = true
            retryDelay = 2
            timeout?.cancel()
            notificationCheck?.cancel()
            status("TRIKI connected")
        }
        for transition in transitions {
            switch transition {
            case .pressed:
                NSLog("button pressed")
                handlePress()
            case .released:
                NSLog("button released")
            }
        }
        // Always parse button state, including in Work mode, so switching modes
        // while holding the button cannot manufacture a new press.
        guard mode == .music else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let reversed = UserDefaults.standard.bool(forKey: "reverseVolumeRotation")
        for frame in frames {
            if let key = rotation.consume(frame, at: now, reversed: reversed) {
                MediaKeyController.send(key)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if self.peripheral === peripheral, invalidatedServices.contains(where: { $0.uuid == Self.service }) {
            fail("UART service invalidated; reconnecting")
        }
    }

    private func handlePress() {
        pendingPress?.cancel()
        let actions = pressGesture.press(at: ProcessInfo.processInfo.systemUptime)
        for action in actions { perform(action) }
        guard let deadline = pressGesture.deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let action = self.pressGesture.expire(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.perform(action)
        }
        pendingPress = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    private func perform(_ action: PressGestureDetector.Action) {
        switch action {
        case .double:
            NSLog("Double press: switching mode")
            onDoublePress()
        case .single:
            switch mode {
            case .music: MediaKeyController.playPause()
            case .work: onWorkPress()
            }
        }
    }

    private func cancelPendingPress() {
        pendingPress?.cancel()
        pendingPress = nil
        pressGesture.cancel()
    }

    private func fail(_ message: String) {
        NSLog("%@", message)
        timeout?.cancel()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
            // Do not depend on a disconnect callback for a failed connection attempt.
            disconnected(peripheral, error: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, error: error)
    }

    private func disconnected(_ peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        NSLog("TRIKI disconnected%@", error.map { ": \($0.localizedDescription)" } ?? "")
        timeout?.cancel()
        clearConnection()
        guard !stopped, central.state == .poweredOn else { return }
        status("TRIKI disconnected; retrying…")
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 30)
    }

    func stop() {
        stopped = true
        retry?.cancel()
        timeout?.cancel()
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        clearConnection()
    }

    private func clearConnection() {
        cancelPendingPress()
        rotation = RotationVolumeController()
        parser.discardPartialFrame()
        notificationCheck?.cancel()
        receivedIMU = false
        peripheral?.delegate = nil
        peripheral = nil
        rx = nil
        tx = nil
        streamStarted = false
    }
}
