//
//  JoyConManager.swift
//  JoyConSwift
//
//  Created by magicien on 2019/06/16.
//  Copyright © 2019 DarkHorse. All rights reserved.
//

import Foundation
import IOKit
import IOKit.hid

let controllerTypeOutputReport: [UInt8] = [
    JoyCon.OutputType.subcommand.rawValue, // type
    0x0f, // packet counter
    0x00, 0x01, 0x00, 0x40, 0x00, 0x01, 0x00, 0x40, // rumble data
    Subcommand.CommandType.getSPIFlash.rawValue, // subcommand type
    0x12, 0x60, 0x00, 0x00, // address
    0x01, // data length
]

/// Connection lifecycle state reported to the app layer
public enum ConnectionState {
    case matching
    case initializing
    case connected
    case error(ConnectionError)
}

/// Specific connection failure reasons
public enum ConnectionError {
    case typeQueryFailed(retryCount: Int)
    case typeQueryTimeout
    case initializationTimeout
    case reseizeFailed
    case communicationFailure
}

/// The manager class to handle controller connection/disconnection events
public class JoyConManager {
    static let vendorID: Int32 = 0x057E
    static let joyConLID: Int32 = 0x2006 // Joy-Con (L)
    static let joyConRID: Int32 = 0x2007 // Joy-Con (R), Famicom Controller 1&2
    static let proConID: Int32 = 0x2009 // Pro Controller
    static let snesConID: Int32 = 0x2017 // SNES Controller
    
    static let joyConLType: UInt8 = 0x01
    static let joyConRType: UInt8 = 0x02
    static let proConType: UInt8 = 0x03
    static let famicomCon1Type: UInt8 = 0x07
    static let famicomCon2Type: UInt8 = 0x08
    static let snesConType: UInt8 = 0x0B

    private let manager: IOHIDManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var matchingControllers: [IOHIDDevice: MatchingState] = [:]
    private var controllers: [IOHIDDevice: Controller] = [:]
    private var runLoop: RunLoop? = nil
        
    /// Handler for a controller connection event
    public var connectHandler: ((_ controller: Controller) -> Void)? = nil
    /// Handler for a controller disconnection event
    public var disconnectHandler: ((_ controller: Controller) -> Void)? = nil

    /// Handler for connection state changes (matching, initializing, connected, error)
    public var connectionStateHandler: ((_ device: IOHIDDevice, _ state: ConnectionState) -> Void)? = nil

    /// Internal state for devices in the matching phase
    private struct MatchingState {
        var retryCount: Int = 0
        var hasReseized: Bool = false
        var timer: Timer?
    }

    /// Initialize a manager
    public init() {}
    
    let handleMatchCallback: IOHIDDeviceCallback = { (context, result, sender, device) in
        let manager: JoyConManager = unsafeBitCast(context, to: JoyConManager.self)
        manager.handleMatch(result: result, sender: sender, device: device)
    }
    
    let handleInputCallback: IOHIDValueCallback = { (context, result, sender, value) in
        let manager: JoyConManager = unsafeBitCast(context, to: JoyConManager.self)
        manager.handleInput(result: result, sender: sender, value: value)
    }
    
    let handleRemoveCallback: IOHIDDeviceCallback = { (context, result, sender, device) in
        let manager: JoyConManager = unsafeBitCast(context, to: JoyConManager.self)
        manager.handleRemove(result: result, sender: sender, device: device)
    }
    
    func handleMatch(result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
        if self.controllers.contains(where: { (dev, _) in dev == device }) {
            return
        }
        if self.matchingControllers[device] != nil {
            return
        }

        self.matchingControllers[device] = MatchingState()
        self.connectionStateHandler?(device, .matching)
        self.sendTypeQueryWithTimeout(device: device)
    }
    
    func handleControllerType(device: IOHIDDevice, result: IOReturn, value: IOHIDValue) {
        guard self.matchingControllers[device] != nil else { return }
        let ptr = IOHIDValueGetBytePtr(value)
        let address = ReadUInt32(from: ptr+14)
        let length = Int((ptr+18).pointee)
        guard address == 0x6012, length == 1 else { return }
        let buffer = UnsafeBufferPointer(start: ptr+19, count: length)
        let data = Array(buffer)
        
        var _controller: Controller? = nil
        switch data[0] {
        case JoyConManager.joyConLType:
            _controller = JoyConL(device: device)
            break
        case JoyConManager.joyConRType:
            _controller = JoyConR(device: device)
            break
        case JoyConManager.proConType:
            _controller = ProController(device: device)
            break
        case JoyConManager.famicomCon1Type:
            _controller = FamicomController1(device: device)
            break
        case JoyConManager.famicomCon2Type:
            _controller = FamicomController2(device: device)
            break
        case JoyConManager.snesConType:
            _controller = SNESController(device: device)
            break
        default:
            break
        }
        
        guard let controller = _controller else { return }
        self.matchingControllers[device]?.timer?.invalidate()
        self.matchingControllers.removeValue(forKey: device)
        self.controllers[device] = controller
        controller.errorHandler = { [weak self] error in
            self?.connectionStateHandler?(device, .error(error))
        }
        controller.isConnected = true
        self.connectionStateHandler?(device, .initializing)
        controller.readInitializeData { [weak self] in
            self?.connectionStateHandler?(device, .connected)
            self?.connectHandler?(controller)
        }
    }
    
    func handleInput(result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
        guard let sender = sender else { return }
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue();
        
        if self.matchingControllers[device] != nil {
            self.handleControllerType(device: device, result: result, value: value)
            return
        }
        
        guard let controller = self.controllers[device] else { return }
        if (result == kIOReturnSuccess) {
            controller.handleInput(value: value)
        } else {
            controller.handleError(result: result, value: value)
        }
    }
    
    func handleRemove(result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
        if self.matchingControllers[device] != nil {
            self.matchingControllers[device]?.timer?.invalidate()
            self.matchingControllers.removeValue(forKey: device)
            return
        }

        guard let controller = self.controllers[device] else { return }
        controller.isConnected = false
        
        self.controllers.removeValue(forKey: device)
        controller.cleanUp()
        
        self.disconnectHandler?(controller)
    }
    
    private func sendTypeQueryWithTimeout(device: IOHIDDevice) {
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0x01), controllerTypeOutputReport, controllerTypeOutputReport.count)
        if result != kIOReturnSuccess {
            let retryCount = self.matchingControllers[device]?.retryCount ?? 0
            self.connectionStateHandler?(device, .error(.typeQueryFailed(retryCount: retryCount)))
            NSLog("IOHIDDeviceSetReport error: %d (retry %d)", result, retryCount)
        }
        self.scheduleMatchingTimeout(for: device)
    }

    private func scheduleMatchingTimeout(for device: IOHIDDevice) {
        self.matchingControllers[device]?.timer?.invalidate()
        guard let runLoop = self.runLoop else { return }

        let timer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.handleMatchingTimeout(device: device)
        }
        runLoop.add(timer, forMode: .default)
        self.matchingControllers[device]?.timer = timer
    }

    private func handleMatchingTimeout(device: IOHIDDevice) {
        guard var state = self.matchingControllers[device] else { return }

        state.retryCount += 1
        let maxRetries = 3

        if !state.hasReseized && state.retryCount >= maxRetries {
            // First round of retries exhausted — attempt force re-seize
            NSLog("Type query timed out after %d retries, attempting re-seize", maxRetries)
            state.hasReseized = true
            state.retryCount = 0
            self.matchingControllers[device] = state

            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

            // Schedule re-open after 500ms on the HID RunLoop
            let reopenTimer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                let reopenResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                if reopenResult != kIOReturnSuccess {
                    NSLog("Re-seize failed with error: %d", reopenResult)
                    self?.matchingControllers[device]?.timer?.invalidate()
                    self?.matchingControllers.removeValue(forKey: device)
                    self?.connectionStateHandler?(device, .error(.reseizeFailed))
                    return
                }
                self?.sendTypeQueryWithTimeout(device: device)
                self?.connectionStateHandler?(device, .matching)
            }
            self.runLoop?.add(reopenTimer, forMode: .default)
            return
        }

        if state.hasReseized && state.retryCount >= maxRetries {
            // Exhausted all attempts after re-seize
            self.matchingControllers[device]?.timer?.invalidate()
            self.matchingControllers.removeValue(forKey: device)
            self.connectionStateHandler?(device, .error(.reseizeFailed))
            NSLog("Controller matching exhausted all retry attempts after re-seize")
            return
        }

        // Retry: resend type query
        self.matchingControllers[device] = state
        self.sendTypeQueryWithTimeout(device: device)
        self.connectionStateHandler?(device, .matching)
    }

    private func registerDeviceCallback() {
        IOHIDManagerRegisterDeviceMatchingCallback(self.manager, self.handleMatchCallback, unsafeBitCast(self, to: UnsafeMutableRawPointer.self))
        IOHIDManagerRegisterDeviceRemovalCallback(self.manager, self.handleRemoveCallback, unsafeBitCast(self, to: UnsafeMutableRawPointer.self))
        IOHIDManagerRegisterInputValueCallback(self.manager, self.handleInputCallback, unsafeBitCast(self, to: UnsafeMutableRawPointer.self))
    }
    
    private func unregisterDeviceCallback() {
        IOHIDManagerRegisterDeviceMatchingCallback(self.manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(self.manager, nil, nil)
        IOHIDManagerRegisterInputValueCallback(self.manager, nil, nil)
    }
    
    private func cleanUp() {
        self.matchingControllers.values.forEach { state in
            state.timer?.invalidate()
        }
        self.matchingControllers.removeAll()
        self.controllers.values.forEach { controller in
            controller.cleanUp()
        }
        self.controllers.removeAll()
    }
        
    /// Start waiting for controller connection/disconnection events in the current thread.
    /// If you don't want to stop the current thread, use `runAsync()` instead.
    /// - Returns: kIOReturnSuccess if succeeded. IOReturn error value if failed.
    public func run() -> IOReturn {
        let joyConLCriteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad,
            kIOHIDVendorIDKey: JoyConManager.vendorID,
            kIOHIDProductIDKey: JoyConManager.joyConLID,
        ]
        let joyConRCriteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad,
            kIOHIDVendorIDKey: JoyConManager.vendorID,
            kIOHIDProductIDKey: JoyConManager.joyConRID,
        ]
        let proConCriteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad,
            kIOHIDVendorIDKey: JoyConManager.vendorID,
            kIOHIDProductIDKey: JoyConManager.proConID,
        ]
        let snesConCriteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad,
            kIOHIDVendorIDKey: JoyConManager.vendorID,
            kIOHIDProductIDKey: JoyConManager.snesConID,
        ]
        let criteria = [joyConLCriteria, joyConRCriteria, proConCriteria, snesConCriteria]
        
        let runLoop = RunLoop.current
        self.runLoop = runLoop

        IOHIDManagerSetDeviceMatchingMultiple(self.manager, criteria as CFArray)
        IOHIDManagerScheduleWithRunLoop(self.manager, runLoop.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)
        let ret = IOHIDManagerOpen(self.manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if (ret != kIOReturnSuccess) {
            print("Failed to open HID manager")
            return ret
        }
        
        self.registerDeviceCallback()

        self.runLoop?.run()
 
        IOHIDManagerClose(self.manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        IOHIDManagerUnscheduleFromRunLoop(self.manager, runLoop.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)

        return kIOReturnSuccess
    }
    
    /// Start waiting for controller connection/disconnection events in a new thread.
    /// If you want to wait for the events synchronously, use `run()` instead.
    /// - Returns: kIOReturnSuccess if succeeded. IOReturn error value if failed.
    public func runAsync() -> IOReturn {
        DispatchQueue.global().async { [weak self] in
            _ = self?.run()
        }
        return kIOReturnSuccess
    }
    
    /// Stop waiting for controller connection/disconnection events
    public func stop() {
        if let currentLoop = self.runLoop?.getCFRunLoop() {
            CFRunLoopStop(currentLoop)
        }

        self.unregisterDeviceCallback()
        self.cleanUp()
    }
}
