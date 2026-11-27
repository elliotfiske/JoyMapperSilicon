import XCTest
@testable import JoyMapperSilicon

/// Byte strings here were captured from the real Joy-Con 2s on this Mac (see the log lines in
/// ~/Library/Logs/JoyMapperSilicon).
final class Switch2ProtocolTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    func testParsesPairingModeAdvertisementForRight() {
        let data = bytes("53 05 01 00 03 7e 05 66 20 00 01 00 00 00 00 00 00 00 0f 00 00 00 00 00 00 00")
        let advertisement = Switch2Protocol.parseAdvertisement(data)
        XCTAssertEqual(advertisement?.kind, .joyCon2Right)
        XCTAssertEqual(advertisement?.isPairingMode, true)
    }

    func testParsesReconnectAdvertisementForLeft() {
        let data = bytes("53 05 01 00 03 7e 05 67 20 00 01 00 55 20 a2 14 b2 fc 0f 00 00 00 00 00 00 00")
        let advertisement = Switch2Protocol.parseAdvertisement(data)
        XCTAssertEqual(advertisement?.kind, .joyCon2Left)
        XCTAssertEqual(advertisement?.pairedHost, [0x55, 0x20, 0xa2, 0x14, 0xb2, 0xfc])
        XCTAssertEqual(advertisement?.isPairingMode, false)
    }

    func testIgnoresOtherManufacturersAndProducts() {
        let apple = bytes("4c 00 01 00 03 7e 05 66 20 00 01 00 00 00 00 00 00 00 0f 00")
        XCTAssertNil(Switch2Protocol.parseAdvertisement(apple))
        let proController = bytes("53 05 01 00 03 7e 05 69 20 00 01 00 00 00 00 00 00 00 0f 00")
        XCTAssertNil(Switch2Protocol.parseAdvertisement(proController))
    }

    func testCommandFraming() {
        XCTAssertEqual(
            Switch2Protocol.setPlayerLights(0x01).data,
            bytes("09 91 01 07 00 08 00 00 01 00 00 00 00 00 00 00")
        )
        XCTAssertEqual(Switch2Protocol.setFeatureMask.data, bytes("0c 91 01 02 00 04 00 00 37 00 00 00"))
        XCTAssertEqual(Switch2Protocol.enableFeatures.data, bytes("0c 91 01 04 00 04 00 00 37 00 00 00"))
    }

    func testPairingSendsHostAddressLittleEndianTwice() {
        let commands = Switch2Protocol.pairingCommands(hostAddress: [0xFC, 0xB2, 0x14, 0xA2, 0x20, 0x55])
        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(
            commands[0].data,
            bytes("15 91 01 01 00 0e 00 00 00 02 55 20 a2 14 b2 fc 55 20 a2 14 b2 fc")
        )
        XCTAssertEqual(commands[3].data, bytes("15 91 01 03 00 01 00 00 00"))
    }

    func testRepliesMatchByCommandAndSubcommand() {
        let enable = Switch2Protocol.enableFeatures
        XCTAssertTrue(enable.isAnswered(by: bytes("0c 01 01 04 10 78 00 00 00 00 00 00")))
        XCTAssertFalse(enable.isAnswered(by: bytes("0c 01 01 02 10 78 00 00 00 00 00 00")))
    }

    func testParsesRightJoyConReport() throws {
        // Idle R report: no buttons, stick near center, 3449 mV.
        let idle = bytes("3e 0e 00 00 00 00 00 e0 ff 0f ff f7 7f 1c d8 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 79 0d 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        let report = try XCTUnwrap(Switch2Protocol.parseReport(idle, kind: .joyCon2Right))
        XCTAssertEqual(Switch2Protocol.buttons(from: report.buttonBits, kind: .joyCon2Right), [])
        XCTAssertEqual(report.rawStick, Switch2Protocol.RawStick(x: 0x81c, y: 0x74d))
        XCTAssertEqual(report.batteryMillivolts, 3449)

        // Byte 7's 0xe0 is always set on this controller; it must not turn into buttons.
        XCTAssertEqual(report.buttonBits & 0xFF00_0000, 0xE000_0000)
    }

    func testDecodesButtonsForEachSide() {
        // A (0x08) + ZR (0x80) on R; ZL (0x80 in byte 6) on L.
        XCTAssertEqual(Switch2Protocol.buttons(from: 0x0000_0088, kind: .joyCon2Right), [.a, .zr])
        XCTAssertEqual(Switch2Protocol.buttons(from: 0x0080_0000, kind: .joyCon2Left), [.zl])
        // Home (0x1000) and C (0x4000) are in the shared byte.
        XCTAssertEqual(Switch2Protocol.buttons(from: 0x0000_5000, kind: .joyCon2Right), [.home, .c])
        // An L-side bit on an R controller is ignored.
        XCTAssertEqual(Switch2Protocol.buttons(from: 0x0080_0000, kind: .joyCon2Right), [])
    }

    func testCalibrationFromReadReply() throws {
        // Real R reply: center (2113, 1856), above (1124, 1274), below (1280, 1169).
        let reply = bytes("02 01 01 04 10 78 00 00 09 00 00 00 a8 30 01 00 41 08 74 64 a4 4f 00 15 49")
        let raw = try XCTUnwrap(Switch2Protocol.calibrationBytes(fromReadReply: reply))
        let calibration = try XCTUnwrap(Switch2Protocol.StickCalibration(bytes: raw))
        XCTAssertEqual(calibration.center, Switch2Protocol.RawStick(x: 2113, y: 1856))
        XCTAssertEqual(calibration.maxSpan, Switch2Protocol.RawStick(x: 1124, y: 1274))
        XCTAssertEqual(calibration.minSpan, Switch2Protocol.RawStick(x: 1280, y: 1169))

        let centered = calibration.normalize(calibration.center)
        XCTAssertEqual(centered, .zero)
        let fullRight = calibration.normalize(Switch2Protocol.RawStick(x: 2113 + 1124, y: 1856))
        XCTAssertEqual(fullRight.x, 1, accuracy: 0.001)
        let pastDown = calibration.normalize(Switch2Protocol.RawStick(x: 2113, y: 0))
        XCTAssertEqual(pastDown.y, -1, accuracy: 0.001)
    }

    func testUnsetCalibrationIsRejected() {
        XCTAssertNil(Switch2Protocol.StickCalibration(bytes: Array(repeating: 0xFF, count: 9)))
    }
}
