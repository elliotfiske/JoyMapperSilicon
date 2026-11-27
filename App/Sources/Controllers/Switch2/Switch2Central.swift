import CoreBluetooth
import Foundation
import IOBluetooth

/// Finds Joy-Con 2s over Bluetooth LE, connects, runs the setup commands, keeps the link alive and
/// feeds decoded input to the mapping engine.
///
/// Everything runs on one serial queue. The store hears about connection changes through
/// `events`; input reports go straight to the engine.
final class Switch2Central: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "JoyMapperSilicon.BLE", qos: .userInteractive)
    private let engine: MappingEngine
    private var central: CBCentralManager?
    private var sessions: [UUID: Session] = [:]
    /// Controllers the user disconnected. They aren't reconnected until they're seen in pairing
    /// mode or the app restarts.
    private var userDisconnected: Set<UUID> = []
    private var logRawReports = false
    private var isScanning = false
    private var hostAddress: [UInt8]?

    private let continuation: AsyncStream<ControllerEvent>.Continuation
    let events: AsyncStream<ControllerEvent>

    init(engine: MappingEngine) {
        self.engine = engine
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(200))
        super.init()
    }

    // MARK: - Public (thread-safe)

    /// Creates the central manager, which asks for Bluetooth permission the first time.
    func start() {
        queue.async {
            guard self.central == nil else { return }
            Log.ble.notice("Starting Bluetooth")
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    func disconnect(_ id: String) {
        queue.async {
            guard let uuid = UUID(uuidString: id) else { return }
            self.userDisconnected.insert(uuid)
            guard let session = self.sessions[uuid] else { return }
            Log.ble.notice("\(session.tag) disconnecting at the user's request")
            self.central?.cancelPeripheralConnection(session.peripheral)
        }
    }

    func setRawReportLogging(_ isOn: Bool) {
        queue.async {
            self.logRawReports = isOn
            Log.ble.notice("Raw report logging \(isOn ? "on" : "off")")
        }
    }

    // MARK: - Session

    private final class Session {
        let peripheral: CBPeripheral
        let kind: ControllerKind
        let wasPairingMode: Bool
        var phase: ConnectionPhase = .connecting
        var writeCharacteristic: CBCharacteristic?
        var inputCharacteristic: CBCharacteristic?
        var pending: [Switch2Protocol.Command] = []
        var inFlight: Switch2Protocol.Command?
        var inFlightAttempts = 0
        var inFlightSentAt = Date.distantPast
        var calibration = Switch2Protocol.StickCalibration.fallback
        var keepAlive: DispatchSourceTimer?
        var connectTimeout: DispatchWorkItem?
        var reportCount = 0
        var lastBatteryLevel: Double?
        var firstReportAt: Date?
        var lastButtonBits: UInt32 = 0

        init(peripheral: CBPeripheral, kind: ControllerKind, wasPairingMode: Bool) {
            self.peripheral = peripheral
            self.kind = kind
            self.wasPairingMode = wasPairingMode
        }

        var id: String { peripheral.identifier.uuidString }
        /// For log lines: "R 66EC9A1C".
        var tag: String {
            let side = kind == .joyCon2Left ? "L" : "R"
            return "\(side) \(peripheral.identifier.uuidString.prefix(8))"
        }
    }

    private func setPhase(_ phase: ConnectionPhase, for session: Session) {
        guard session.phase != phase else { return }
        session.phase = phase
        Log.ble.notice("\(session.tag) → \(phase.displayText)")
        continuation.yield(.phase(id: session.id, kind: session.kind, phase))
    }

    // MARK: - Scanning

    private func startScanning() {
        guard let central, central.state == .poweredOn, !isScanning else { return }
        // Joy-Con 2s advertise no service UUIDs, so scan for everything and filter on manufacturer
        // data. Duplicates on: a reconnect advertisement is a short burst after a button press.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        continuation.yield(.scanning(true))
        Log.ble.info("Scanning for Joy-Con 2s")
    }

    private func shouldConnect(_ uuid: UUID, advertisement: Switch2Protocol.Advertisement) -> Bool {
        if sessions[uuid] != nil { return false }
        if advertisement.isPairingMode {
            // The user is holding SYNC: they want it connected, even if they disconnected it before.
            userDisconnected.remove(uuid)
            return true
        }
        if userDisconnected.contains(uuid) { return false }
        // A reconnect advertisement names the host it's paired with. Only take the ones paired to us.
        let ours = hostAddress.map { Array($0.reversed()) }
        return advertisement.pairedHost == ours
    }

    // MARK: - Setup commands

    private func startSetup(_ session: Session) {
        setPhase(.initializing, for: session)
        let lights = Switch2Protocol.setPlayerLights(Self.playerLights(for: session.kind))
        session.pending = [
            Switch2Protocol.readFactoryStickCalibration,
            lights,
            Switch2Protocol.setFeatureMask,
            Switch2Protocol.enableFeatures,
        ]
        if session.wasPairingMode {
            session.pending += pairingCommands(for: session)
        }
        sendNextCommand(session)
    }

    private func pairingCommands(for session: Session) -> [Switch2Protocol.Command] {
        guard let hostAddress else {
            Log.ble.error("\(session.tag) can't read this Mac's Bluetooth address; skipping pairing (SYNC will be needed each time)")
            return []
        }
        let writeLimit = session.peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard writeLimit >= 25 else {
            Log.ble.error("\(session.tag) write limit \(writeLimit) is too small for pairing; skipping it")
            return []
        }
        Log.ble.notice("\(session.tag) was in pairing mode: pairing it to this Mac so a button press reconnects it")
        return Switch2Protocol.pairingCommands(hostAddress: hostAddress)
    }

    private func sendNextCommand(_ session: Session) {
        guard session.inFlight == nil else { return }
        guard let write = session.writeCharacteristic else { return }
        guard !session.pending.isEmpty else {
            finishSetupIfNeeded(session)
            return
        }
        let command = session.pending.removeFirst()
        session.inFlight = command
        session.inFlightAttempts = 1
        session.inFlightSentAt = Date()
        Log.ble.info("\(session.tag) → \(command.label): \(command.data.hexString)")
        session.peripheral.writeValue(command.data, for: write, type: .withoutResponse)
        scheduleCommandTimeout(session, command: command)
    }

    /// Writes can be lost. Resend after 500 ms, up to 3 times, then move on.
    private func scheduleCommandTimeout(_ session: Session, command: Switch2Protocol.Command) {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak session] in
            guard let self, let session, session.inFlight == command else { return }
            guard let write = session.writeCharacteristic else { return }
            if session.inFlightAttempts < 3 {
                session.inFlightAttempts += 1
                Log.ble.info("\(session.tag) no reply to \(command.label); resending (attempt \(session.inFlightAttempts))")
                session.peripheral.writeValue(command.data, for: write, type: .withoutResponse)
                self.scheduleCommandTimeout(session, command: command)
            } else {
                Log.ble.error("\(session.tag) gave up on \(command.label) after 3 attempts")
                session.inFlight = nil
                self.sendNextCommand(session)
            }
        }
    }

    private func handleCommandReply(_ reply: Data, session: Session) {
        let isKeepAlive = session.phase == .ready && reply.first == 0x09
        if logRawReports || !isKeepAlive {
            Log.ble.debug("\(session.tag) ← \(reply.hexString)")
        }
        guard let command = session.inFlight, command.isAnswered(by: reply) else { return }
        session.inFlight = nil

        if command == Switch2Protocol.readFactoryStickCalibration {
            applyCalibration(from: reply, session: session)
        }
        if command.id == 0x15 {
            Log.ble.notice("\(session.tag) \(command.label) acknowledged")
        }
        sendNextCommand(session)
    }

    private func applyCalibration(from reply: Data, session: Session) {
        let bytes = Switch2Protocol.calibrationBytes(fromReadReply: reply)
        let calibration = bytes.flatMap(Switch2Protocol.StickCalibration.init(bytes:))
        guard let calibration else {
            Log.ble.error("\(session.tag) stick calibration unreadable (\(reply.hexString)); using defaults")
            return
        }
        session.calibration = calibration
        Log.ble.notice("\(session.tag) stick calibration center=(\(calibration.center.x),\(calibration.center.y)) above=(\(calibration.maxSpan.x),\(calibration.maxSpan.y)) below=(\(calibration.minSpan.x),\(calibration.minSpan.y))")
    }

    private func finishSetupIfNeeded(_ session: Session) {
        guard session.phase == .initializing else { return }
        guard let input = session.inputCharacteristic else {
            setPhase(.failed("no input characteristic"), for: session)
            return
        }
        session.peripheral.setNotifyValue(true, for: input)
        startKeepAlive(session)
    }

    /// macOS drops a Joy-Con 2 link 10–17 s after the host's last write, even while reports are
    /// flowing. Re-sending the player lights once a second keeps it up.
    private func startKeepAlive(_ session: Session) {
        session.keepAlive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak session] in
            guard let session, session.inFlight == nil, session.pending.isEmpty else { return }
            guard let write = session.writeCharacteristic else { return }
            let lights = Switch2Protocol.setPlayerLights(Self.playerLights(for: session.kind))
            session.peripheral.writeValue(lights.data, for: write, type: .withoutResponse)
        }
        timer.resume()
        session.keepAlive = timer
    }

    private static func playerLights(for kind: ControllerKind) -> UInt8 {
        // One solid LED, like a console's player 1 (L) and player 2 (R).
        kind == .joyCon2Left ? 0x01 : 0x03
    }

    // MARK: - Input

    private func handleInputReport(_ data: Data, session: Session) {
        session.reportCount += 1
        if session.firstReportAt == nil {
            session.firstReportAt = Date()
            setPhase(.ready, for: session)
        }
        if logRawReports, session.reportCount % 30 == 1 {
            Log.ble.debug("\(session.tag) report #\(session.reportCount): \(data.hexString)")
        }
        if session.reportCount % 600 == 0, let first = session.firstReportAt {
            let rate = Double(session.reportCount) / Date().timeIntervalSince(first)
            Log.ble.info("\(session.tag) \(session.reportCount) reports, \(String(format: "%.1f", rate))/s average")
        }

        guard let report = Switch2Protocol.parseReport(data, kind: session.kind) else {
            Log.ble.error("\(session.tag) short report (\(data.count) bytes)")
            return
        }
        if report.buttonBits != session.lastButtonBits {
            session.lastButtonBits = report.buttonBits
            Log.ble.debug("\(session.tag) button bits 0x\(String(report.buttonBits, radix: 16))")
        }
        let input = ControllerInput(
            buttons: Switch2Protocol.buttons(from: report.buttonBits, kind: session.kind),
            stick: session.calibration.normalize(report.rawStick)
        )
        engine.receive(input, from: session.id)
        reportBattery(millivolts: report.batteryMillivolts, session: session)
    }

    private func reportBattery(millivolts: Int, session: Session) {
        guard let level = Switch2Protocol.batteryLevel(millivolts: millivolts) else { return }
        if let last = session.lastBatteryLevel, abs(last - level) < 0.05 { return }
        session.lastBatteryLevel = level
        Log.ble.info("\(session.tag) battery \(millivolts) mV ≈ \(Int(level * 100))%")
        continuation.yield(.battery(id: session.id, level: level))
    }

    private func tearDown(_ session: Session, reason: String) {
        session.keepAlive?.cancel()
        session.connectTimeout?.cancel()
        sessions[session.peripheral.identifier] = nil
        engine.controllerDisconnected(session.id)
        Log.ble.notice("\(session.tag) disconnected: \(reason) (after \(session.reportCount) reports)")
        setPhase(.disconnected, for: session)
    }

    private static func readHostAddress() -> [UInt8]? {
        guard let text = IOBluetoothHostController.default()?.addressAsString() else { return nil }
        let parts = text.split { $0 == "-" || $0 == ":" }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        return bytes
    }
}

// MARK: - CBCentralManagerDelegate

extension Switch2Central: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state: BluetoothState
        switch central.state {
        case .poweredOn: state = .poweredOn
        case .poweredOff: state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: state = .unknown
        }
        Log.ble.notice("Bluetooth state: \(state.rawValue)")
        continuation.yield(.bluetooth(state))
        if state == .poweredOn {
            if hostAddress == nil {
                hostAddress = Self.readHostAddress()
                let text = hostAddress.map { $0.map { String(format: "%02X", $0) }.joined(separator: ":") } ?? "unknown"
                Log.ble.info("This Mac's Bluetooth address: \(text)")
            }
            startScanning()
        } else {
            isScanning = false
            continuation.yield(.scanning(false))
            for session in sessions.values {
                tearDown(session, reason: "Bluetooth \(state.rawValue)")
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        guard let advertisement = Switch2Protocol.parseAdvertisement(data) else { return }
        guard shouldConnect(peripheral.identifier, advertisement: advertisement) else { return }

        let session = Session(peripheral: peripheral, kind: advertisement.kind, wasPairingMode: advertisement.isPairingMode)
        sessions[peripheral.identifier] = session
        let mode = advertisement.isPairingMode ? "pairing mode" : "reconnecting"
        Log.ble.notice("\(session.tag) found (\(mode), RSSI \(RSSI)); connecting. Advertisement: \(data.hexString)")
        continuation.yield(.discovered(id: session.id, kind: session.kind))
        setPhase(.connecting, for: session)
        peripheral.delegate = self
        central.connect(peripheral)

        // Repeated fast connects can wedge the controller until SYNC, so give each one 10 s.
        let timeout = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, session.phase == .connecting else { return }
            Log.ble.error("\(session.tag) connect timed out")
            central.cancelPeripheralConnection(session.peripheral)
            self.tearDown(session, reason: "connect timed out")
        }
        session.connectTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let session = sessions[peripheral.identifier] else { return }
        session.connectTimeout?.cancel()
        let writeLimit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        Log.ble.notice("\(session.tag) connected (write limit \(writeLimit) bytes); discovering")
        peripheral.discoverServices([Switch2Protocol.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let session = sessions[peripheral.identifier] else { return }
        let reason = error?.localizedDescription ?? "unknown error"
        setPhase(.failed(reason), for: session)
        tearDown(session, reason: "connect failed: \(reason)")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let session = sessions[peripheral.identifier] else { return }
        tearDown(session, reason: error?.localizedDescription ?? "closed")
    }
}

// MARK: - CBPeripheralDelegate

extension Switch2Central: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let session = sessions[peripheral.identifier] else { return }
        let service = peripheral.services?.first { $0.uuid == Switch2Protocol.service }
        guard let service else {
            Log.ble.error("\(session.tag) has no Joy-Con 2 service: \(error?.localizedDescription ?? "not found")")
            setPhase(.failed("Joy-Con 2 service not found"), for: session)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        let wanted = [Switch2Protocol.inputReport, Switch2Protocol.commandWrite, Switch2Protocol.commandResponse]
        peripheral.discoverCharacteristics(wanted, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let session = sessions[peripheral.identifier] else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Switch2Protocol.commandWrite: session.writeCharacteristic = characteristic
            case Switch2Protocol.inputReport: session.inputCharacteristic = characteristic
            case Switch2Protocol.commandResponse: peripheral.setNotifyValue(true, for: characteristic)
            default: break
            }
        }
        guard session.writeCharacteristic != nil, session.inputCharacteristic != nil else {
            Log.ble.error("\(session.tag) is missing its command or input characteristic")
            setPhase(.failed("missing characteristics"), for: session)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let session = sessions[peripheral.identifier] else { return }
        if let error {
            Log.ble.error("\(session.tag) couldn't subscribe to \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        Log.ble.info("\(session.tag) subscribed to \(characteristic.uuid.uuidString.prefix(8))")
        // Replies have somewhere to go now, so the setup commands can start.
        if characteristic.uuid == Switch2Protocol.commandResponse {
            startSetup(session)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let session = sessions[peripheral.identifier], let value = characteristic.value else { return }
        switch characteristic.uuid {
        case Switch2Protocol.inputReport: handleInputReport(value, session: session)
        case Switch2Protocol.commandResponse: handleCommandReply(value, session: session)
        default: break
        }
    }
}
