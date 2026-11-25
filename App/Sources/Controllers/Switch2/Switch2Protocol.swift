import CoreBluetooth
import Foundation

/// The Joy-Con 2 Bluetooth LE protocol: advertisement parsing, command framing and input reports.
///
/// Joy-Con 2s aren't Bluetooth HID devices. They speak Nintendo's own protocol over GATT:
/// - Commands go to one characteristic (write without response).
/// - Replies come back on another (notify).
/// - Input reports stream on a third (notify).
///
/// Reference: `.context/switch2-ble-protocol.md` (from ndeadly/switch2_controller_research, SDL and
/// switch2mac), checked against a real Joy-Con 2 (R) on this Mac.
enum Switch2Protocol {
    // MARK: GATT

    static let service = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0")
    /// Input report "0x05": 63 bytes per notification, the same layout for L and R.
    static let inputReport = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2")
    static let commandWrite = CBUUID(string: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005")
    static let commandResponse = CBUUID(string: "C765A961-D9D8-4D36-A20A-5315B111836A")

    // MARK: Advertisement

    /// Nintendo's Bluetooth company ID, little-endian, at the start of the manufacturer data.
    static let companyID: [UInt8] = [0x53, 0x05]

    struct Advertisement: Equatable {
        var kind: ControllerKind
        /// The host the controller is paired with, or nil in pairing mode (SYNC held).
        var pairedHost: [UInt8]?

        var isPairingMode: Bool { pairedHost == nil }
    }

    static func parseAdvertisement(_ data: Data) -> Advertisement? {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x12 else { return nil }
        guard Array(bytes[0..<2]) == companyID else { return nil }
        // USB vendor ID 0x057E, little-endian.
        guard bytes[5] == 0x7E, bytes[6] == 0x05 else { return nil }

        let productID = UInt16(bytes[7]) | UInt16(bytes[8]) << 8
        guard let kind = ControllerKind(productID: productID) else { return nil }

        let host = Array(bytes[0x0C..<0x12])
        let isZero = host.allSatisfy { $0 == 0 }
        return Advertisement(kind: kind, pairedHost: isZero ? nil : host)
    }

    // MARK: Commands

    /// An 8-byte header (command, direction 0x91 = host→device, transport 0x01 = BLE, subcommand,
    /// 0, payload length, 0, 0) then the payload.
    struct Command: Equatable {
        var id: UInt8
        var subcommand: UInt8
        var payload: [UInt8]
        var label: String

        var data: Data {
            let header: [UInt8] = [id, 0x91, 0x01, subcommand, 0x00, UInt8(payload.count), 0x00, 0x00]
            return Data(header + payload)
        }

        /// Replies echo the command and subcommand in bytes 0 and 3.
        func isAnswered(by reply: Data) -> Bool {
            reply.count >= 4 && reply[reply.startIndex] == id && reply[reply.startIndex + 3] == subcommand
        }
    }

    /// Lights the player LEDs. `pattern` is a bitmask of the four LEDs (0x01 = player 1). Also the
    /// keep-alive: macOS drops the link 10–17 s after the last write.
    static func setPlayerLights(_ pattern: UInt8) -> Command {
        Command(id: 0x09, subcommand: 0x07, payload: [pattern, 0, 0, 0, 0, 0, 0, 0], label: "set player lights")
    }

    /// Buttons, sticks, IMU and battery current (0x37, what the console sends to Joy-Cons).
    static let featureMask: UInt8 = 0x37

    static var setFeatureMask: Command {
        Command(id: 0x0C, subcommand: 0x02, payload: [featureMask, 0, 0, 0], label: "set feature mask")
    }

    static var enableFeatures: Command {
        Command(id: 0x0C, subcommand: 0x04, payload: [featureMask, 0, 0, 0], label: "enable features")
    }

    /// Reads factory stick calibration: 9 bytes at 0x130A8. Both Joy-Cons use this primary slot.
    static var readFactoryStickCalibration: Command {
        Command(id: 0x02, subcommand: 0x04, payload: [0x09, 0x7E, 0x00, 0x00, 0xA8, 0x30, 0x01, 0x00], label: "read stick calibration")
    }

    /// The commands that make the controller remember this Mac, so a button press reconnects it
    /// without SYNC. `hostAddress` is the Mac's Bluetooth address in display order (AA:BB:…).
    /// Only send these while the controller is in pairing mode.
    static func pairingCommands(hostAddress: [UInt8]) -> [Command] {
        let littleEndian = Array(hostAddress.reversed())
        return [
            Command(id: 0x15, subcommand: 0x01, payload: [0x00, 0x02] + littleEndian + littleEndian, label: "pair: host address"),
            Command(id: 0x15, subcommand: 0x04, payload: [0x00] + pairingKeyA1, label: "pair: key"),
            Command(id: 0x15, subcommand: 0x02, payload: [0x00] + pairingChallengeA2, label: "pair: challenge"),
            Command(id: 0x15, subcommand: 0x03, payload: [0x00], label: "pair: finish"),
        ]
    }

    /// Fixed values other PC hosts use. The controller stores an LTK derived from these, but we
    /// reconnect unencrypted, so they don't need to be secret or random.
    private static let pairingKeyA1: [UInt8] = [
        0xEA, 0xBD, 0x47, 0x13, 0x89, 0x35, 0x42, 0xC6, 0x79, 0xEE, 0x07, 0xF2, 0x53, 0x2C, 0x6C, 0x31,
    ]
    private static let pairingChallengeA2: [UInt8] = [
        0x40, 0xB0, 0x8A, 0x5F, 0xCD, 0x1F, 0x9B, 0x41, 0x12, 0x5C, 0xAC, 0xC6, 0x3F, 0x38, 0xA0, 0x73,
    ]

    // MARK: Input report

    /// Bit masks in the little-endian u32 at offset 4.
    static let buttonBits: [(ControllerButton, UInt32)] = [
        (.y, 0x0000_0001), (.x, 0x0000_0002), (.b, 0x0000_0004), (.a, 0x0000_0008),
        (.rightSR, 0x0000_0010), (.rightSL, 0x0000_0020), (.r, 0x0000_0040), (.zr, 0x0000_0080),
        (.minus, 0x0000_0100), (.plus, 0x0000_0200), (.rightStick, 0x0000_0400), (.leftStick, 0x0000_0800),
        (.home, 0x0000_1000), (.capture, 0x0000_2000), (.c, 0x0000_4000),
        (.down, 0x0001_0000), (.up, 0x0002_0000), (.right, 0x0004_0000), (.left, 0x0008_0000),
        (.leftSR, 0x0010_0000), (.leftSL, 0x0020_0000), (.l, 0x0040_0000), (.zl, 0x0080_0000),
    ]

    struct Report: Equatable {
        var buttonBits: UInt32
        var rawStick: RawStick
        var batteryMillivolts: Int
    }

    struct RawStick: Equatable {
        var x: Int
        var y: Int
    }

    static func parseReport(_ data: Data, kind: ControllerKind) -> Report? {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x22 else { return nil }

        let buttons = UInt32(bytes[4])
            | UInt32(bytes[5]) << 8
            | UInt32(bytes[6]) << 16
            | UInt32(bytes[7]) << 24

        // Each Joy-Con's stick is in its own side's field; the other field holds junk.
        let stickOffset = kind == .joyCon2Left ? 0x0A : 0x0D
        let stick = unpackStick(bytes[stickOffset], bytes[stickOffset + 1], bytes[stickOffset + 2])

        let millivolts = Int(bytes[0x1F]) | Int(bytes[0x20]) << 8
        return Report(buttonBits: buttons, rawStick: stick, batteryMillivolts: millivolts)
    }

    /// Two 12-bit values packed in three bytes. Larger y is up.
    static func unpackStick(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> RawStick {
        let x = Int(b0) | (Int(b1 & 0x0F) << 8)
        let y = (Int(b1) >> 4) | (Int(b2) << 4)
        return RawStick(x: x, y: y)
    }

    static func buttons(from bits: UInt32, kind: ControllerKind) -> Set<ControllerButton> {
        let ownButtons = Set(kind.buttons)
        var result: Set<ControllerButton> = []
        for (button, mask) in buttonBits where bits & mask != 0 && ownButtons.contains(button) {
            result.insert(button)
        }
        return result
    }

    // MARK: Stick calibration

    /// Center, and how far the stick travels above and below it, per axis.
    struct StickCalibration: Equatable {
        var center: RawStick
        var maxSpan: RawStick
        var minSpan: RawStick

        /// Measured on Joy-Con 2s when the controller's own calibration can't be read.
        static let fallback = StickCalibration(
            center: RawStick(x: 2048, y: 2048),
            maxSpan: RawStick(x: 1180, y: 1180),
            minSpan: RawStick(x: 1180, y: 1180)
        )

        /// Nine bytes: center, max span, min span, each a packed 12-bit pair.
        init?(bytes: [UInt8]) {
            guard bytes.count >= 9 else { return nil }
            guard !bytes.prefix(9).allSatisfy({ $0 == 0xFF }) else { return nil }
            center = unpackStick(bytes[0], bytes[1], bytes[2])
            maxSpan = unpackStick(bytes[3], bytes[4], bytes[5])
            minSpan = unpackStick(bytes[6], bytes[7], bytes[8])
            let spans = [maxSpan.x, maxSpan.y, minSpan.x, minSpan.y]
            guard spans.allSatisfy({ $0 > 200 }) else { return nil }
        }

        init(center: RawStick, maxSpan: RawStick, minSpan: RawStick) {
            self.center = center
            self.maxSpan = maxSpan
            self.minSpan = minSpan
        }

        func normalize(_ raw: RawStick) -> StickVector {
            StickVector(
                x: Self.axis(raw.x, center: center.x, above: maxSpan.x, below: minSpan.x),
                y: Self.axis(raw.y, center: center.y, above: maxSpan.y, below: minSpan.y)
            )
        }

        private static func axis(_ value: Int, center: Int, above: Int, below: Int) -> Double {
            let offset = Double(value - center)
            let span = Double(offset > 0 ? above : below)
            guard span > 0 else { return 0 }
            return min(max(offset / span, -1), 1)
        }
    }

    /// The 9 calibration bytes in a memory-read reply: an 8-byte header, then
    /// `len 00 00 00 addr(4)`, then the data.
    static func calibrationBytes(fromReadReply reply: Data) -> [UInt8]? {
        let bytes = [UInt8](reply)
        guard bytes.count >= 16 + 9 else { return nil }
        return Array(bytes[16..<(16 + 9)])
    }

    /// A rough percentage from the reported voltage. The reading sits about 0.6 V below the cell
    /// voltage, so this is only good for "full / half / low". Range is a guess; tune it with real
    /// readings (the log has the millivolts).
    static func batteryLevel(millivolts: Int) -> Double? {
        guard millivolts > 0 else { return nil }
        let empty = 2900.0
        let full = 3500.0
        let level = (Double(millivolts) - empty) / (full - empty)
        return min(max(level, 0), 1)
    }
}
