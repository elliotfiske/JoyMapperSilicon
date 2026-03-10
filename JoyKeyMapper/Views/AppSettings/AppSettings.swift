//
//  AppSettings.swift
//  JoyKeyMapper
//
//  Created by magicien on 2020/03/12.
//  Copyright © 2020 DarkHorse. All rights reserved.
//

import Foundation
import ServiceManagement

class AppSettings {
    static var disconnectTime: Int {
        get {
            return UserDefaults.standard.integer(forKey: "disconnectTime")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "disconnectTime")
        }
    }

    static var notifyConnection: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "notifyConnection")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "notifyConnection")
        }
    }

    static var notifyBatteryLevel: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "notifyBatteryLevel")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "notifyBatteryLevel")
        }
    }

    static var notifyBatteryCharge: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "notifyBatteryCharge")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "notifyBatteryCharge")
        }
    }

    static var notifyBatteryFull: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "notifyBatteryFull")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "notifyBatteryFull")
        }
    }

    static var launchOnLogin: Bool {
        get {
            return SMAppService.mainApp.status == .enabled
        }
    }

    static func setLaunchOnLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
