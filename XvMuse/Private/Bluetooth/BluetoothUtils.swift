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


