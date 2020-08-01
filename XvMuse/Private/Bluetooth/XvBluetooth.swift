//
//  XvBluetooth.swift
//  XvBluetooth
//
//  Created by Jason Snell on 5/17/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//

/*
 
 DESIGN:
 
 Main file:
 This file is the overall manager, a singleton. This is the access point to the framework.
 
 Listerer file:
 Listeners are individual objects, each one listens to it's own bluetooth device in scenarios where there are multiple
 
 The listener is init'd with the UUID's of the device and characteritics. Each bluetooth device needs to be programmed to at least have unique device UUID's
 
 The listeners handle their own Bluetooth manager and peripheral functions, from discovery to notification listening
 
 When a listener "hears" incoming data, it will post a Notification so listeners in the app can receive the notification, unpack its device UUID, characteristic UUID, and value. This way it can determine which device the data value came
 
 Utils file:
 helpers for the Listener object
 
 */

/*
 
 Usage
 addListener(deviceUUID: device, characteristicsUUIDs: [x, y, z)
 
 */


import Foundation
import CoreBluetooth

//MARK: - View Controller -

public protocol XvBluetoothObserver:class {
    
    func update(state:String)
    
    //connecting
    func discovered(targetDevice:CBPeripheral)
    func discovered(nearbyDevice:CBPeripheral)
    func discovered(service:CBService)
    func discovered(characteristic:CBCharacteristic)
    
    //receive data
    func received(valueFromCharacteristic:CBCharacteristic, fromDevice:CBPeripheral)
    
    //disconnecting
    func didLoseConnection() // headband connection fails
    func didDisconnect() //head receives disconnect command
    
}


public class XvBluetooth {
    
    //vars
    fileprivate var listeners:[BluetoothListener] = []
    
    //singleton code
    public static let sharedInstance = XvBluetooth()
    fileprivate init() {}
    
    public func addListener(
        observer:XvBluetoothObserver,
        deviceUUID:CBUUID?,
        serviceUUID:CBUUID?,
        characteristicsUUIDs:[CBUUID]){
        
        let listener:BluetoothListener = BluetoothListener(
            observer: observer,
            deviceUUID: deviceUUID,
            serviceUUID: serviceUUID,
            characteristicsUUIDs: characteristicsUUIDs
        )
        
        listeners.append(listener)
        
    }
    
    public func connect(){
        
        for listener in listeners {
            
            //the the device ID is valid, print it
            if (listener.deviceUUID != nil) {
                print("BLUETOOTH: Attempt connection to", listener.deviceUUID!)
                
            } else if (listener.deviceUUID == nil) {
                //if not, alert user that a scan of all nearby devices will occur
                print("Scanning for all nearby Bluetooth devices and will print their CBUUID's")
            }
            
            listener.connect()
        }
    }
    
    public func disconnect(){
        
        //print("BLUETOOTH: Disconnect")
        
        for listener in listeners {
            listener.disconnect()
        }
        
    }
    
    public func write(data:Data, toDeviceWithID:CBUUID, forCharacteristicWithID:CBUUID, withType:CBCharacteristicWriteType) {
        
        for listener in listeners {
            
            listener.write(
                data: data,
                toDeviceWithID: toDeviceWithID,
                forCharacteristicWithID: forCharacteristicWithID,
                withType: withType
            )
        }
    }
}



