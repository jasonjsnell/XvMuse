//
//  BluetoothUtils.swift
//  XvBluetooth
//
//  Created by Jason Snell on 5/17/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//

import Foundation
import CoreBluetooth

class BluetoothUtils {
    
    
    //MARK: - DEBUG
    
    class func getDesc(forState:CBManagerState) -> String {
        
        var msg:String = ""
        
        switch forState {
            
        case .poweredOn:
            msg = "Bluetooth on the central managing device is currently powered on."
        case .poweredOff:
            msg = "Bluetooth on this central managing device is currently powered off."
        case .unsupported:
            msg = "The central managing device does not support Bluetooth Low Energy."
        case .unauthorized:
            msg = "This app is not authorized to use Bluetooth Low Energy."
        case .resetting:
            msg = "The BLE Manager is resetting; a state update is pending."
        case .unknown:
            msg = "The state of the BLE Manager is unknown."
        default:
             msg = "The state of the BLE Manager is unknown."
        }
        
        return msg
        
    }
    
    class func printState(state:CBManagerState) {

        print("BLUETOOTH:", getDesc(forState:state))

    }

    ///One word, for log lines that are read in sequence. getDesc is a sentence
    ///meant for on-screen display and is too long to scan in a console.
    class func shortName(forState:CBManagerState) -> String {

        switch forState {
        case .poweredOn:    return "poweredOn"
        case .poweredOff:   return "poweredOff"
        case .unsupported:  return "unsupported"
        case .unauthorized: return "unauthorized"
        case .resetting:    return "resetting"
        case .unknown:      return "unknown"
        @unknown default:   return "unrecognized(\(forState.rawValue))"
        }
    }

    /* SEPARATE FROM STATE, and the distinction is the whole point on iOS.

     CBManagerState says whether the radio is usable right now. Authorization says
     what the user has decided about this app. They fail differently and the fix is
     different, but both surface as "no devices found":

     notDetermined  the permission prompt has not been shown yet. On iOS the prompt
                    fires when the first CBCentralManager is created, so seeing this
                    after a scan attempt means no central manager was ever made.
     denied         the user said no. Only Settings can undo it; no amount of
                    rescanning will help.
     restricted     blocked by parental controls or MDM.
     allowedAlways  fine. Any failure is elsewhere.

     Mac builds effectively never hit the first three, which is why a bug here can
     hide for a long time in a codebase that is developed on macOS. */
    class func authDesc() -> String {

        switch CBManager.authorization {
        case .notDetermined:  return "notDetermined (prompt not shown yet)"
        case .restricted:     return "restricted (parental controls / MDM)"
        case .denied:         return "denied (user declined; fix in Settings)"
        case .allowedAlways:  return "allowedAlways"
        @unknown default:     return "unrecognized"
        }
    }
    
    // debugs the type of incoming characteristic
    
    class func printType(forCharacteristic:CBCharacteristic){
        
        if forCharacteristic.properties.contains(.broadcast) {
            print("Characteristic type: broadcast")
        }
        
        if forCharacteristic.properties.contains(.read) {
            print("Characteristic type: read")
        }
        
        if forCharacteristic.properties.contains(.writeWithoutResponse) {
            print("Characteristic type: writeWithoutResponse")
        }
        
        if forCharacteristic.properties.contains(.write) {
            print("Characteristic type: write")
        }
        
        if forCharacteristic.properties.contains(.notify) {
            print("Characteristic type: notify")
        }
        
        if forCharacteristic.properties.contains(.indicate) {
            print("Characteristic type: indicate")
        }
        
        if forCharacteristic.properties.contains(.authenticatedSignedWrites) {
            print("Characteristic type: authenticatedSignedWrites")
        }
        
        if forCharacteristic.properties.contains(.extendedProperties) {
            print("Characteristic type: extendedProperties")
        }
        
        if forCharacteristic.properties.contains(.notifyEncryptionRequired) {
            print("Characteristic type: notifyEncryptionRequired")
        }
        
        if forCharacteristic.properties.contains(.indicateEncryptionRequired) {
            print("Characteristic type: indicateEncryptionRequired")
        }
        
    }
    
    
    
    
}


