# Switch 2 Joy-Con 2 (L/R) BLE Protocol Reference (for CoreBluetooth on macOS)

Researched 2026-11-25. This covers Joy-Con 2 L and R only. It leaves out the mouse sensor, IMU, rumble, Pro Controller 2 and the GameCube controller, except where they share a structure.

Confidence key:
- **High**: the primary research doc (ndeadly) agrees with 2+ independent working implementations.
- **Medium**: one working implementation, or sources that agree only partly.
- **Low**: inference, or a single unverified claim.

Source short names (full links in section 9):
- **ND**: ndeadly/switch2_controller_research, from sniffed console traffic plus fuzzing. This is the primary reference.
- **SDL**: libsdl-org/SDL `SDL_hidapi_switch2.c` (USB, but the same report and command formats).
- **S2M**: Peterksharma/switch2mac, a shipping Swift and CoreBluetooth macOS app. This is the closest match to your target.
- **NAD**: Nadeflore/switch2-controllers (Python, bleak).
- **J2W**: Logan-Gaillard/Joy2Win (Python, bleak).
- **SEI**: seitanmen/Joycon2forMac (Objective-C++ and CoreBluetooth).
- **JOE**: JoeGeC/joycon2android, `docs/protocol.md`, with many hardware measurements.
- **TRV**: trevlars/switch2-controllers-linux.
- **BR**: darthcloud/BlueRetro `main/bluetooth/hidp/sw2.c` (an ESP32 host that controls its own HCI).

I could not reach the Bit Axis Labs blog posts: `bit-axis-labs.pages.dev` failed DNS resolution from this machine, and web.archive.org is blocked for the fetch tool. Nothing below depends on them.

---

## 0. TL;DR: recommended minimal flow

1. Scan with `scanForPeripherals(withServices: nil, options: [AllowDuplicates: true])`. Keep peripherals whose manufacturer data starts with `53 05` (company 0x0553), has VID `7E 05` at index 5, and has PID `67 20` (L) or `66 20` (R) at index 7.
2. `connect`. Do not trigger SMP pairing; CoreBluetooth won't as long as you don't touch encrypted attributes, and none of these attributes are encrypted.
3. Discover the characteristics in service `AB7DE9BE-89FE-49AD-828F-118F09DF7FD0`, or discover all of them.
4. Subscribe (notify) to the command response characteristic `C765A961-D9D8-4D36-A20A-5315B111836A`.
5. Write commands **without response** to `649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005`, one at a time, waiting for each echo:
   - Optional: read the stick calibration.
   - Set the player LED: `09 91 01 07 00 08 00 00 01 00 00 00 00 00 00 00`.
   - Set the feature mask: `0C 91 01 02 00 04 00 00 37 00 00 00`.
   - Enable the features: `0C 91 01 04 00 04 00 00 37 00 00 00`.
6. Subscribe (notify) to the input report characteristic `AB7DE9BE-89FE-49AD-828F-118F09DF7FD2`. 63-byte reports then stream at the connection-event rate (about 66 Hz on macOS).
7. **Every ~1 s, write something**, for example the LED command again. Otherwise macOS drops the link 10 to 17 s after the last write (S2M).
8. Optional, for reconnect without the SYNC button: send the `0x15` "pairing" commands once while the controller is in pairing mode (section 3).

Bonding is **not** required to receive input (ND, and every PC implementation). Overall confidence in this flow is High for steps 1 to 6, and Medium for steps 7 and 8.

---

## 1. Discovery

### 1.1 Advertising PDU (High: ND, S2M, NAD, J2W, JOE)

- The PDU is `ADV_IND` (connectable, undirected).
- It carries only two AD structures: Flags `0x06` and Manufacturer Specific Data (`0xFF`).
- **There is no local name and no service UUID.** You must scan with `withServices: nil` and filter on manufacturer data.

`CBAdvertisementDataManufacturerDataKey` gives the whole manufacturer-data payload, **including** the 2-byte company ID. The indices below are into that `Data`, and they match ND's offsets.

| Index | Size | Value | Meaning | Confidence |
|---|---|---|---|---|
| 0x00 | 2 | `53 05` | Company ID 0x0553 (Nintendo), little-endian | High |
| 0x02 | 1 | `01` | unknown, constant | High |
| 0x03 | 1 | `00` | unknown, constant | High |
| 0x04 | 1 | `03` | unknown, constant | High |
| 0x05 | 2 | `7E 05` | USB VID 0x057E, little-endian | High |
| 0x07 | 2 | `67 20` / `66 20` | **PID, little-endian: 0x2067 = Joy-Con 2 L, 0x2066 = Joy-Con 2 R** (0x2069 = Pro 2, 0x2073 = NSO GC) | High |
| 0x09 | 1 | `00` | unknown | High |
| 0x0A | 1 | `01` | unknown | High |
| 0x0B | 1 | `00` / `81` | `81` = "wake console" advertisement, `00` otherwise | High (ND) |
| 0x0C | 6 | host address | Bluetooth address of the paired host, **byte-reversed** (little-endian). **All zero = pairing mode** (SYNC held, or never paired). | High |
| 0x12 | 1 | `0F` | unknown, constant | High |
| 0x13 | 7 | `00…` | reserved | High |

Examples from ND. These are Pro Controller captures (PID `69 20`); a Joy-Con has the same shape with `67 20` or `66 20`.

```
pairing / standard: 53 05 01 00 03 7e 05 69 20 00 01 00 00 00 00 00 00 00 0f 00 00 00 00 00 00 00
reconnection:       53 05 01 00 03 7e 05 69 20 00 01 00 5f 11 85 eb f1 48 0f 00 00 00 00 00 00 00
wake console:       53 05 01 00 03 7e 05 69 20 00 01 81 5f 11 85 eb f1 48 0f 00 00 00 00 00 00 00
```

JOE gives a Joy-Con R example of the pairing advertisement (company ID already stripped): `01 00 03 7E 05 66 20 00 01 00 [00×6] 0F …`.

**Telling L from R (High).** The PID at index 7 is the only identification in the advertisement:
- 0x2067 = **Left** and 0x2066 = **Right**. Your guess had them the other way round.
- Sources for this mapping: ND's USB descriptors, the `USB_PRODUCT_NINTENDO_SWITCH2_JOYCON_LEFT/RIGHT` constants in SDL `usb_ids.h`, S2M, NAD (`JOYCON2_LEFT_PID = 0x2067`), and JOE, which confirmed it on hardware.
- BlueRetro's `sw2.h` names them the other way round (`SW2_LJC_PID 0x2066`), but it treats both the same, so that naming is just wrong. Treat it as an outlier (C1).
- After connecting you can confirm the side in three ways:
  - by which per-side characteristic UUIDs exist (section 2.2),
  - by the PID in the info-block read (factory data at `0x13014`),
  - by which stick field moves in the input report.

**Pairing mode compared with reconnect (High).**
- Pairing mode: the host-address field (index 0x0C to 0x11) is all zeros.
- Reconnect or wake: the field holds the stored host's address. The controller only sends this after a button press on a controller that has stored a host, and JOE notes the burst is short.
- NAD and S2M connect when the address is zero, or when it equals the local adapter's address.

### 1.2 How the user enters pairing mode (High: S2M, TRV, SEI, NAD READMEs)

- Hold the small **SYNC** button on the Joy-Con 2's rail side, the flat side that slides onto the console, until the four player LEDs sweep (chase).
- The controller then advertises the zero-address form for a limited time.
- The Joy-Con must not currently be connected to a Switch 2. If it was last paired to a console that is nearby and asleep, a normal button press sends a "wake console" advertisement to that console instead.

---

## 2. GATT layout

### 2.1 Common attributes, identical on L and R (High: ND table; UUIDs used by S2M, NAD, J2W, SEI, TRV, BR)

The main service is `AB7DE9BE-89FE-49AD-828F-118F09DF7FD0`. The handles come from ND's table; don't rely on them in CoreBluetooth.

| Handle | UUID | Properties | Use |
|---|---|---|---|
| 0x000A | `AB7DE9BE-89FE-49AD-828F-118F09DF7FD2` | READ, NOTIFY | **Input report "0x05"** (common format, all controllers). **Subscribe to this one.** |
| 0x000B | `2902` | CCCD | `01 00` enables notifications |
| 0x000C | `679D5510-5A24-4DEE-9557-95DF80486ECB` | descriptor | "Set report rate?": the console writes `85 00` here (unknown meaning) |
| 0x0014 | `649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005` | WRITE_NO_RESPONSE | **Command write** (8-byte header + data) |
| 0x0018 | `4147423D-FDAE-4DF7-A4F7-D23E5DF59F8D` | WRITE_NO_RESPONSE | Chunked "large command" (firmware update). Not needed. |
| 0x001A | `C765A961-D9D8-4D36-A20A-5315B111836A` | NOTIFY | **Command response** for commands written to 0x0014. **Subscribe before you write any command.** |
| 0x0022 | `D3BD69D2-841C-4241-AB15-F86F406D2A80` | NOTIFY | unknown; JOE says it never notifies |
| 0x0026 | `AB7DE9BE-89FE-49AD-828F-118F09DF7FDE` | READ, NOTIFY | unknown; JOE says it never notifies |
| 0x002A | `AB7DE9BE-89FE-49AD-828F-118F09DF7FDF` | WRITE_NO_RESPONSE | unknown. JOE: "Writing to the similar-looking `…fdf` enables a subscription that never delivers data." |

There is also a service `00C5AF5D-1964-4E30-8F51-1956F96BD280` with characteristics `…281` (READ), `…282` (WRITE) and `…283` (READ). The console writes `01 00` to `…282` first, which JOE calls "session start". No PC implementation that uses the common channel does this, so it isn't needed.

The standard services are also present: `1800` (Device Name, Appearance) and `1801`. The `1801` service has **no** characteristics, so there is no Service Changed characteristic (ND).

### 2.2 Per-side attributes (used by the console; an alternative path, not needed)

| Handle | Joy-Con 2 **L** UUID | Joy-Con 2 **R** UUID | Properties | Use |
|---|---|---|---|---|
| 0x000E | `CC1BBBB5-7354-4D32-A716-A81CB241A32A` | `D5A9E01E-2FFC-4CCA-B20C-8B67142BF442` | READ, NOTIFY | Input report 0x07 (L) / 0x08 (R): compact, side-specific (section 5.4) |
| 0x0012 | `289326CB-A471-485D-A8F4-240C14F18241` | `FA19B0FB-CD1F-46A7-84A1-BBB09E00C149` | WRITE_NO_RESPONSE | Rumble output report |
| 0x0016 | `CE49A830-DCED-48AE-931E-C8CF88AADBEA` | `65A724B3-F1E7-4A61-8078-A342376B27FF` | WRITE_NO_RESPONSE | Rumble + command: `00` + 16 rumble bytes + command |
| 0x001E | `63A3810F-AEC7-474B-9010-3D52403CB996` | `640CA58E-0E88-410C-A7F3-426FAF2B690B` | NOTIFY | Response to commands sent on 0x0016 (14 leading zero bytes, then the header) |

These UUIDs also give you a second way to detect L or R after discovery (High, ND).

**Which path to use (High).** Every PC implementation reviewed uses the common path:
- notify on `…FD2`,
- write to `649D4AC9…`,
- notify on `C765A961…`.

That path gives one unified button layout for L and R, and the commands have no padding prefix. The console uses the per-side 0x0016/0x001E/0x000E path. JOE found third-party Joy-Con 2 clones (NYXI) that only implement the per-side path.

---

## 3. Bonding and pairing

### 3.1 Is it needed to get input? **No.** (High)

- ND (`bluetooth_interface.md`, "Pairing"): "Pairing itself is optional for communicating with the controller and receiving notifications etc. via PC and other devices…" The console needs it; a PC does not.
- Every implementation reviewed (S2M, NAD, J2W, SEI, JOE, TRV) connects unencrypted, subscribes, sends a few commands, and receives input. SEI and JOE never pair at all.
- **Never let standard SMP pairing happen.**
  - ND: "Attempting to pair controllers using SMP (as many platforms do automatically) will cause the controller to terminate the connection."
  - JOE observed the link drop with status 22.
  - CoreBluetooth only starts pairing when you access an attribute that needs encryption. None of these do, so a plain connect is safe (S2M).
- NAD tells users to remove the controller from the OS Bluetooth settings if they paired it there. The same applies to macOS System Settings.

### 3.2 Reconnect without the SYNC button: the app-layer "pairing" (Medium)

The controller stores its host through command `0x15` over GATT, not through SMP. Once a host is stored, a button press makes the controller advertise with that host's address (section 1.1), and the host connects.

The console flow (ND, captured):

1. `15/01`: send the host addresses. The console sends 2 addresses: its address, then the same address with the lowest byte minus 1.
2. `15/04`: send host key A1 (16 bytes). The controller replies with B1, which is always `5CF6EE792CDF05E1BA2B6325C41A5F10`.
3. `LTK = A1 XOR B1`.
4. `15/02`: send challenge A2. The controller replies with `B2 = AES128-ECB(key = reverse(LTK), block = reverse(A2))`.
5. `15/03`: finalise. The controller commits the addresses and LTK to flash at `0x1FA000`.

The console then uses this LTK for **link-layer encryption** on later connections. ND's reconnect captures are encrypted, and BR reads the LTK back from flash (`0x1FA01A`, 16 bytes) and calls HCI `LE Start Encryption`.

**CoreBluetooth can't set an LTK, but it doesn't appear to need one.**
- NAD (Windows), S2M (macOS) and TRV (Linux) send these commands and then reconnect **unencrypted** after a wake advertisement.
- S2M's README claims "auto-reconnecting on any button press once paired" on macOS.
- They send fixed A1/A2 values and never check B2.

The minimal writes, as used by S2M, NAD and BR, all to `649D4AC9…` without response:

```
15 91 01 01 00 0E 00 00  00 02  <MAC LE 6 bytes>  <MAC LE 6 bytes>
15 91 01 04 00 11 00 00  00  EA BD 47 13 89 35 42 C6 79 EE 07 F2 53 2C 6C 31
15 91 01 02 00 11 00 00  00  40 B0 8A 5F CD 1F 9B 41 12 5C AC C6 3F 38 A0 73
15 91 01 03 00 01 00 00  00
```

Notes on these writes:
- `<MAC LE>` is the Mac's **public** Bluetooth address, byte-reversed. S2M reads it with `IOBluetoothHostController.default()?.addressAsString()`, then parses and reverses the bytes.
- S2M and NAD send the same address twice. The console and BR send the address, then the address with byte[0] minus 1.
- J2W instead uses ND's captured Joy-Con A1/A2: `08 06 5a 60 e9 02 e4 e1 02 02 9e 3f a3 9a 78 d1` / `93 4e 58 0f 16 3a ee cf b5 75 fc 91 36 b2 2f bb`.

Expected responses on `C765A961…`, from ND:

```
15 01 01 01 10 78 00 00  01 04 01 <controller addr LE 6 bytes>
15 01 01 04 10 78 00 00  01 5C F6 EE 79 2C DF 05 E1 BA 2B 63 25 C4 1A 5F 10   (B1)
15 01 01 02 10 78 00 00  01 <16 bytes B2>
15 01 01 03 10 78 00 00  01
```

**Caveats** (each one Medium or Low):
- **P1. The controller seems to filter the connecting device's address.**
  - JOE (Android): after storing the phone as host, the wake advertisement carried the phone's address. The phone could still not connect, because Android initiates from a resolvable private address. The link dropped with `0x3E`, the same as for a Joy-Con stored to another host.
  - So reconnect works only if macOS initiates from the same public address you stored.
  - S2M's success on macOS suggests it does. That is one source (Medium).
- **P2. Pairing to the Mac likely replaces the console's pairing.** JOE: "Pairing replaces the console's entry: SYNC on the Switch 2 restores it." The flash layout keeps two entries, but they are the console's primary and secondary addresses. Attaching the Joy-Con to the console rails re-pairs it to the console (Medium). Warn users.
- **P3. `15/01` on its own doesn't change the stored host** (JOE). Send all four commands.
- **P4. Only pair when the advertisement had a zero host address** (pairing mode). S2M gates on this.
- **P5. Reconnect is reported as flaky on Linux** (TRV README). There is no equivalent report for macOS.

If you skip pairing, the UX is "hold SYNC every time you want to connect" (JOE, SEI).

---

## 4. Commands

### 4.1 Framing (High: ND, SDL, all implementations)

Request = 8-byte header + data:

| Byte | Request value | Response value | Meaning |
|---|---|---|---|
| 0 | cmd | cmd (echo) | Command ID |
| 1 | `0x91` | `0x01` | Direction: 0x91 = host to device, 0x01 = device to host |
| 2 | `0x01` | `0x01` | Transport: 0x01 = BLE, 0x00 = USB |
| 3 | subcmd | subcmd (echo) | Subcommand |
| 4 | `0x00` | `0x10` | unknown |
| 5 | data length | `0x78` (ACK) | Request: length of the data. Response: ACK. |
| 6–7 | `00 00` | `00 00` | padding |
| 8… | data | response data | |

- Write with `.withoutResponse`; the characteristic is WRITE_NO_RESPONSE only.
- Keep **one command in flight** and correlate replies by bytes 0 and 3 (S2M, NAD, JOE).
- S2M also accepts byte 1 = `0x02` in replies, which it observed as a status or error reply.
- JOE: "A write can be lost". It resends the LED command until it sees the echo: 300 ms apart, at most 5 attempts.

Byte 2 for SPI reads is disputed (C2). ND's console captures, S2M, NAD and BR all use `0x01` for memory reads over BLE and get replies. JOE says reads with `0x01` got no reply on its common-channel setup and that `0x00` works. Default to `0x01`, and retry with `0x00` if no reply arrives within ~500 ms.

### 4.2 Init commands (exact hex)

All of these go to `649D4AC9…`, with replies on `C765A961…`.

| # | Purpose | Request | Expected response | Required? | Source / confidence |
|---|---|---|---|---|---|
| I1 | Read the device info block (0x40 bytes at 0x13000) | `02 91 01 04 00 08 00 00 40 7E 00 00 00 30 01 00` | `02 01 01 04 10 78 00 00 40 00 00 00 00 30 01 00` + 64 data bytes | Optional (gives serial, PID and colours) | ND, S2M, BR. High |
| I2 | Read the user stick calibration (0x0B bytes at 0x1FC040) | `02 91 01 04 00 08 00 00 0B 7E 00 00 40 C0 1F 00` | header + `0B 00 00 00 40 C0 1F 00` + 11 bytes: `B2 A1` magic + 9 calibration bytes, or `FF…` if unset | Optional | SDL (magic check), S2M/NAD (read 0x1FC042). High |
| I3 | Read the factory stick calibration (9 bytes at 0x130A8) | `02 91 01 04 00 08 00 00 09 7E 00 00 A8 30 01 00` | header + `09 00 00 00 A8 30 01 00` + 9 bytes | Optional (needed for good stick scaling) | SDL, S2M, NAD, BR. High |
| I4 | Set player LEDs (pattern `0x01` = P1) | `09 91 01 07 00 08 00 00 01 00 00 00 00 00 00 00` | `09 01 01 07 10 78 00 00` | Optional, but it confirms the link and works as a keep-alive | ND, JOE. High |
| I5 | Set feature mask | `0C 91 01 02 00 04 00 00 37 00 00 00` | `0C 01 01 02 10 78 00 00 00 00 00 00` | **Yes** (ND: must precede enable) | ND, SDL, all. High |
| I6 | Enable features | `0C 91 01 04 00 04 00 00 37 00 00 00` | `0C 01 01 04 10 78 00 00 00 00 00 00` | **Yes** | ND, SDL, all. High |
| I7 | Subscribe to `…FD2` (CCCD `01 00`) | `setNotifyValue(true, …)` | input notifications start | **Yes** | all. High |

Memory-read payload: `len(1) 7E 00 00 addr(4, little-endian)`. The maximum length is `0x4F` over BLE (ND). The reply data starts at response byte 16, because the 8-byte header is followed by `len 00 00 00 addr(4)`.

**Feature flags** (ND `commands.md`, command 0x0C):

| Bit | Feature |
|---|---|
| 0x01 | buttons |
| 0x02 | sticks |
| 0x04 | IMU |
| 0x08 | unused |
| 0x10 | mouse (Joy-Con only) |
| 0x20 | "rumble", plus the battery-current field in report 0x05 |
| 0x40 | unused |
| 0x80 | magnetometer |

Which value to send:
- The console sends `0x37` to Joy-Cons, `0x2F` to Pro and `0x27` to GC (ND init captures).
- SDL (USB) uses `0x27`, then `0x23`/`0x27`.
- TRV uses `0x07`. S2M uses `0xB7` on Joy-Cons.
- J2W, SEI and JOE use `0xFF` on Joy-Cons and it works for them. S2M, citing Switch2Connect, says `0xFF` "induces phantom ZL/ZR bits on Joy-Cons" (C3).
- **Use `0x37`** (the console's Joy-Con value) or `0x03` (buttons and sticks only). The 0x05 report is a fixed 63 bytes either way, so the extra features cost no bandwidth.

**Expected `0x0C/0x01` "get feature info" reply** (only if you want to check): `0c 01 01 01 10 78 00 00 00 00 00 00 07 07 01 00 00 03 00 00` for flags 0x2F on a Pro.

**Player LED patterns.**
- The data byte is a bitmask: bits 0 to 3 are the four LEDs.
- S2M's console-style player patterns: P1 `0x01`, P2 `0x03`, P3 `0x07`, P4 `0x0F`.
- JOE: the high nibble makes LEDs flash, and `0xF0` is the default chase animation.
- ND: fixed-player subcommands also exist, `09/01`..`09/06` with no data (P1..P4, all on, all off).
- NAD says the controller fails if the data is shorter than 4 bytes. Send 8 bytes as the console does, or at least 4.

**Battery queries (optional, ND):**
- `0B 91 01 03 00 00 00 00` returns `… a5 0e 00 00`, the voltage in mV, little-endian (example 0x0EA5 = 3749 mV).
- `0B 91 01 04 00 00 00 00` returns the charge status.
- ND's examples use byte 2 = `00`, which is USB.

**Connection vibration sample (optional):** `0A 91 01 02 00 04 00 00 03 00 00 00` plays the console's "connected" click (ND, J2W, JOE).

**Order** (S2M's working order, consistent with ND):

1. Subscribe to command responses.
2. Info (I1).
3. Calibration (I2, then I3 if I2 is unset).
4. LEDs (I4).
5. Feature mask and enable (I5, I6).
6. `0x15` pairing, only if the advertisement was in pairing mode.
7. Subscribe to input (I7).

SEI and JOE instead subscribe to input first and fire I5 and I6 500 ms apart without waiting for replies. That also works, so the order is not strict.

---

## 5. Input report (common report 0x05 on `…FD2`)

63 bytes per notification. There is no report-ID byte over BLE (ND). Offsets are into `characteristic.value`.

### 5.1 Layout (High: ND `hid_reports.md`, S2M, JOE; SDL offsets + 1 because of the USB report ID)

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | Counter | u32 little-endian, +1 per report. JOE says it behaves like a ms clock. |
| 0x04 | 4 | **Buttons** | bitfield (section 5.2) |
| 0x08 | 2 | unknown | |
| 0x0A | 3 | **Left stick** | packed 12-bit X/Y, uncalibrated. **Joy-Con L's stick is here.** |
| 0x0D | 3 | **Right stick** | packed 12-bit X/Y, uncalibrated. **Joy-Con R's stick is here.** |
| 0x10 | 8 | Mouse | feature 0x10 (ignore) |
| 0x18 | 1 | 0 | |
| 0x19 | 6 | Magnetometer | feature 0x80 (ignore) |
| 0x1F | 2 | **Battery voltage, mV** | u16 little-endian |
| 0x21 | 1 | **Charge state** | changes on USB power; settles around 0x34 while charging, 0x20 when full (ND) |
| 0x22 | 2 | Battery current | feature 0x20; signed, positive while charging (S2M) |
| 0x24 | 5 | 0 | |
| 0x29 | 1 | `01` | |
| 0x2A | 0x12 | Motion | feature 0x04 (ignore) |
| 0x3C | 2 | Analog triggers | GC only |
| 0x3E | 1 | reserved | |

The stick field for the other side holds no useful data. JOE: "A left Joy-Con's right-stick bytes are garbage". Read only the field for the connected side.

### 5.2 Button bitfield (High: ND, SDL, S2M, J2W, JOE all agree)

| Byte offset | 0x80 | 0x40 | 0x20 | 0x10 | 0x08 | 0x04 | 0x02 | 0x01 |
|---|---|---|---|---|---|---|---|---|
| **0x04** (R side) | ZR | R | SL (R) | SR (R) | A | B | X | Y |
| **0x05** (shared) | – | **C** (R) | Capture (L) | Home (R) | L-stick click | R-stick click | Plus (R) | Minus (L) |
| **0x06** (L side) | ZL | L | SL (L) | SR (L) | Left | Right | Up | Down |
| 0x07 | – | – | – | headset (Pro) | – | – | GL (Pro) | GR (Pro) |

The same bits as a little-endian u32 read at offset 4, as S2M does:

```
Y 0x00000001  X 0x00000002  B 0x00000004  A 0x00000008
SR(R) 0x00000010  SL(R) 0x00000020  R 0x00000040  ZR 0x00000080
Minus 0x00000100  Plus 0x00000200  RStick 0x00000400  LStick 0x00000800
Home 0x00001000  Capture 0x00002000  C 0x00004000
Down 0x00010000  Up 0x00020000  Right 0x00040000  Left 0x00080000
SR(L) 0x00100000  SL(L) 0x00200000  L 0x00400000  ZL 0x00800000
```

- **Joy-Con 2 L** uses: Down/Up/Right/Left, SR(L), SL(L), L, ZL, Minus, Capture, L-stick click.
- **Joy-Con 2 R** uses: Y/X/B/A, SR(R), SL(R), R, ZR, Plus, Home, C, R-stick click.

ZL and ZR are digital on Joy-Cons. SDL maps a `0x02`/`0x01` bit at offset 0x07 to "paddle" on Joy-Cons, which ND labels GL/GR (Pro-only). Its meaning on a Joy-Con is unclear (U5), so ignore it.

### 5.3 Stick decoding and calibration

**Packing (High: ND, SDL, S2M, BR, JOE).** Given 3 bytes `b0 b1 b2`:

```
x = b0 | ((b1 & 0x0F) << 8)      // 0...4095
y = (b1 >> 4) | (b2 << 4)        // 0...4095; larger = up (SDL inverts Y for its down-positive convention)
```

**Calibration** (High for the format, Medium for which slot applies to the R Joy-Con):

- Format: 9 bytes, three packed pairs as above: **center**, **max span** (distance above center), **min span** (distance below center).
- To normalise one axis (SDL `MapJoystickAxis`, S2M):

```
d = raw - center
if d > 0: d / maxSpan
else:     d / minSpan
clamp to ±1
```

- Factory slots: primary at `0x130A8` (= 0x13080 + 0x28), secondary at `0x130E8`.
- User slots:
  - SDL reads `0x1FC040` (0x40 bytes) and uses `+2` only if bytes 0 and 1 are `B2 A1`.
  - S2M and NAD read `0x1FC042` directly and treat `FF FF FF` as unset.
  - The secondary user slot is disputed (`0x1FC060`/`0x1FC062` according to ND, S2M and NAD; `0x1FC080` according to SDL), but Joy-Cons don't use it.
- **Both Joy-Cons use the PRIMARY slot**, including the R Joy-Con, whose live data is in the *right* stick field at 0x0D.
  - SDL's Joy-Con R handlers use `ctx->left_stick` calibration, loaded from 0x130A8.
  - S2M: "for the right Joy-Con you must read the stick data from field 2 but calibrate it with the stick-1 calibration… Using the (empty) stick-2 calibration on a right Joy-Con yields a stuck/dead axis."

**Typical values without calibration** (JOE, measured on Joy-Con 2s):
- Travel: left ~900, right ~3400, down ~890, up ~3360. The half-span is about 1250.
- Rest: left Joy-Con x 2080 / y 2157; right Joy-Con x 2014 / y 2022.
- Rest is not the midpoint. If you use 2048 ± 2048, full tilt only reaches about 60%.
- A sensible fallback is center 2048 and span ~1180, with a deadzone.

**Worked example** (ND's factory dump, a Pro Controller primary stick): `B3 67 83 2E 66 5E 3A 06 5F` decodes as:
- center = (0x7B3, 0x836) = (1971, 2102)
- max span = (0x62E, 0x5E6) = (1582, 1510)
- min span = (0x63A, 0x5F0) = (1594, 1520)

### 5.4 Alternative: side-specific reports 0x07 (L) / 0x08 (R) on the 0x000E characteristic (High: ND, SDL, JOE)

You only need these if you use the console channel.

| Offset | L (0x07) | R (0x08) |
|---|---|---|
| 0x00 | 8-bit counter | same |
| 0x01 | **Power**: bit0 external power, bit1 charging, bits2–5 battery level 0–9 | same |
| 0x02 | buttons byte 0 | buttons byte 0 |
| 0x03 | buttons byte 1 | buttons byte 1 |
| 0x04 | `0x07` | `0x07` |
| 0x05 | stick (3 bytes, packed 12-bit) | stick |
| 0x09 | mouse (5 bytes) | mouse |
| 0x0E | motion length | NFC state |
| 0x0F | motion | motion length |

L buttons:
- byte 0: 0x80 Stick, 0x40 Minus, 0x20 ZL, 0x10 L, 0x08 Up, 0x04 Left, 0x02 Right, 0x01 Down
- byte 1: 0x80 SL, 0x40 SR, 0x01 Capture

R buttons:
- byte 0: 0x80 Stick, 0x40 Plus, 0x20 ZR, 0x10 R, 0x08 X, 0x04 Y, 0x02 A, 0x01 B
- byte 1: 0x80 SL, 0x40 SR, 0x10 C, 0x01 Home

SDL's USB parser also reads a `0x04` bit in L byte 1 as "paddle" (U5).

The 0x05 report has no 0–9 battery level, only mV. The 0x07/0x08 reports have the level.

### 5.5 Report rate

- Each connection event delivers one notification, so the report rate equals 1 / connection interval.
- The console uses a 5 ms interval, set through a vendor HCI command. The controller never sends a Connection Parameter Update Request (ND).
- On **macOS, CoreBluetooth picks the interval**, which caps input at about **66 Hz** (15 ms) (S2M `research/PROTOCOL.md` §9). Medium: one source.
- For comparison, JOE measured 33 Hz at Android "balanced" priority (30 ms), 67 Hz at "high" (15 ms), and ~200 Hz when forcing 7.5 ms. Windows is stuck at 60 ms, about 16.7 Hz (ND).

---

## 6. macOS / CoreBluetooth gotchas

- **G1. Don't trigger SMP** (High). Use only unencrypted GATT, and never pair the controller in System Settings, because the controller disconnects. If a user did pair it there, have them remove it ("Forget This Device").
- **G2. Keep-alive write every ~1 s** (Medium, S2M only, but stated precisely and verified over multi-minute sessions).
  - S2M: "On macOS, a connected Switch 2 controller's link is silently terminated ≈10–17 seconds after the host's last write to it, even while input reports are still streaming inbound. Linux and Windows hosts do not exhibit this."
  - S2M re-sends the player-LED command once a second when idle. Rumble writes also count.
- **G3. You can't set connection parameters**, so expect about 66 Hz (section 5.5).
- **G4. MTU** (Medium).
  - Input notifications are 63 bytes, a 0x40-byte memory-read reply is 80 bytes, and pairing writes are 25 bytes.
  - With the default ATT MTU of 23 (20-byte payload), notifications would be truncated and the 25-byte writes would fail.
  - macOS negotiates a larger MTU automatically, and S2M works. Check `peripheral.maximumWriteValueLength(for: .withoutResponse) >= 25`, and check `value.count >= 0x3F` (or at least 0x11 for buttons and sticks) before parsing.
  - JOE on Android had to `requestMtu(247)` explicitly.
- **G5. Write type and flow control** (High). Every write characteristic is WRITE_NO_RESPONSE, so use `.withoutResponse`. For bursts, honour `canSendWriteWithoutResponse` and `peripheralIsReady(toSendWriteWithoutResponse:)`. Keep one command outstanding, wait for its echo, and use a timeout (S2M: 2 s).
- **G6. Scanning** (High). The advertisement carries no service UUID or name, so scan with `withServices: nil` and filter on manufacturer data. Reconnect advertisements are short bursts after a button press, so keep scanning continuously while you wait. `AllowDuplicates: true` helps you see a peripheral again after it drops.
- **G7. CoreBluetooth won't hide the device for being bonded** (High). The controller never SMP-bonds, so macOS has no bond record to hide it behind. It can still be invisible if:
  - it is currently connected to something else, such as the console or another app, or
  - it is not advertising: asleep, and not in SYNC mode or woken by a button.
- **G8. Pending connect for reconnect** (Low: my inference, untested with these controllers). The usual CoreBluetooth auto-reconnect pattern is `retrievePeripherals(withIdentifiers:)` followed by `connect()` with no timeout. It should fire when the controller sends its wake advertisement, but S2M uses scan-then-connect instead.
- **G9. Connect cooldown** (Medium, JOE). Rapid repeated connects make the controller stop responding until SYNC. Back off between retries. S2M times out a connect after 10 s.
- **G10. Two Joy-Cons are two independent peripherals** (High). Each needs its own handshake and keep-alive. TRV serialises connection setup because many adapters allow only one pending LE create-connection. CoreBluetooth queues these itself.
- **G11. Empty `1801` service, no Service Changed** (High, ND). This is harmless with CoreBluetooth (S2M works). Pro Controller firmware updates shift handles, so always look characteristics up by UUID, never by handle.
- **G12. TCC** (Low, inference). As with your Accessibility note, rebuilt or re-signed binaries may prompt for Bluetooth permission again. `NSBluetoothAlwaysUsageDescription` and `com.apple.security.device.bluetooth` are already in `Project.swift` and the entitlements file.
- **G13. Host address for `0x15`** (Medium). On macOS this comes from IOBluetooth (`IOBluetoothHostController.default()?.addressAsString()`), not CoreBluetooth. Reconnect also depends on macOS initiating from that public address (P1).

---

## 7. Conflicts and unknowns

**Conflicts:**
- **C1. PID naming.** BlueRetro labels 0x2066 as L. ND (USB descriptors), SDL, S2M, NAD and JOE (hardware) all say **0x2067 = L, 0x2066 = R**. Trust the majority.
- **C2. Header byte 2 for SPI reads over BLE.** ND, S2M, NAD and BR use `0x01`; JOE says only `0x00` gets a reply. Try `0x01`, then fall back to `0x00`.
- **C3. Feature mask `0xFF` on Joy-Cons.** It works for J2W, SEI and JOE, but S2M reports phantom ZL/ZR with it. Use `0x37` or `0x03`.
- **C4. Secondary user-calibration address.** `0x1FC060`/`0x1FC062` (ND, S2M, NAD) or `0x1FC080` (SDL). This doesn't matter for Joy-Cons.
- **C5. Battery voltage scale.** J2W treats offset 0x1F as `/4095` for a percentage, which is wrong per ND (it is mV). JOE says the reading sits ~0.6 V below the cell voltage. For a percentage, use a voltage-to-percent curve, or the 0–9 level in 0x07/0x08.

**Unknowns:**
- **U1. Does reconnect via the `0x15` host entry need link encryption?** BR encrypts with the LTK; S2M, NAD and TRV don't, and still report working reconnects. CoreBluetooth can only take the unencrypted path.
- **U2. Does macOS initiate LE connections from its public address?** If it uses a private address, button-press reconnect fails the way it does on Android (JOE).
- **U3. Exact macOS report rate.** S2M's README says about 66 Hz, while one of its code comments says 33 Hz. Measure it.
- **U4. Meaning of the `679D5510…` descriptor write `85 00`** ("report rate?") and whether writing it from CoreBluetooth changes anything.
- **U5. The `0x07`-offset bits (and L byte-1 `0x04` in 0x07) that SDL calls Joy-Con "paddles".** It is unknown which physical control this is, if any.
- **U6. Whether pairing to a Mac evicts the console's pairing permanently,** or whether the two coexist. JOE says it evicts.
- **U7. Input before the feature mask is set.** Reports probably flow from CCCD enable, possibly with zeroed fields. Not documented.

---

## 8. Swift sketch (parsing only)

```swift
enum JoyCon2Side { case left, right }

struct JoyCon2Report {
    let buttons: UInt32        // LE u32 at offset 4, bit masks in section 5.2
    let stickX: UInt16
    let stickY: UInt16
    let batteryMillivolts: UInt16

    init?(_ data: Data, side: JoyCon2Side) {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x22 else { return nil }

        let buttonBytes = bytes[4...7]
        buttons = buttonBytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }

        let stickOffset = (side == .left) ? 0x0A : 0x0D
        let b0 = UInt16(bytes[stickOffset])
        let b1 = UInt16(bytes[stickOffset + 1])
        let b2 = UInt16(bytes[stickOffset + 2])
        stickX = b0 | ((b1 & 0x0F) << 8)
        stickY = (b1 >> 4) | (b2 << 4)

        batteryMillivolts = UInt16(bytes[0x1F]) | (UInt16(bytes[0x20]) << 8)
    }
}

func command(_ id: UInt8, _ sub: UInt8, _ payload: [UInt8]) -> Data {
    let header: [UInt8] = [id, 0x91, 0x01, sub, 0x00, UInt8(payload.count), 0x00, 0x00]
    return Data(header + payload)
}
```

---

## 9. Sources

- ND: https://github.com/ndeadly/switch2_controller_research (commit a3306b4)
  - `bluetooth_interface.md`: advertising, pairing, GATT table, console init sequences
  - `hid_reports.md`: reports 0x05/0x07/0x08, button tables
  - `commands.md`: header, 0x02 / 0x09 / 0x0B / 0x0C / 0x15
  - `memory_layout.md`: factory data, calibration, pairing info at 0x1FA000
  - `descriptors.md`: USB PIDs 0x2066 (R) / 0x2067 (L)
- SDL: https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch2.c and https://github.com/libsdl-org/SDL/blob/main/src/joystick/usb_ids.h
- S2M: https://github.com/Peterksharma/switch2mac (commit a8f2e61)
  - `Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift`
  - `Sources/FinallyTheControllerWorks/Bluetooth/ControllerSession.swift`
  - `Sources/FinallyTheControllerWorks/Bluetooth/BridgeEngine.swift`
  - `research/PROTOCOL.md` (macOS keep-alive §9)
- NAD: https://github.com/Nadeflore/switch2-controllers (commit e79720b), `controller.py`, `discoverer.py`
- J2W: https://github.com/Logan-Gaillard/Joy2Win (commit 932d6d7), `controller_command.py`, `controllers/JoyconL.py`, `main.py`
- SEI: https://github.com/seitanmen/Joycon2forMac (commit 65fd964), `src/Joycon2BLEReceiver.mm`
- JOE: https://github.com/JoeGeC/joycon2android (commit 8a1ed94), `docs/protocol.md`
- TRV: https://github.com/trevlars/switch2-controllers-linux (commit a0a36e6), `README.md`, `ngc/device.py`
- BR: https://github.com/darthcloud/BlueRetro (commit e1a9831), `main/bluetooth/hidp/sw2.c`, `sw2.h`
- Not reachable from this machine (DNS failure): https://bit-axis-labs.pages.dev/blog/switch-2-ble-controllers.html, https://bit-axis-labs.pages.dev/blog/nso-gamecube-ble-ios.html
- Not reviewed in depth: espp `switch2_pro` (it emulates a controller, the device side), TheFrano/joycon2cpp.
