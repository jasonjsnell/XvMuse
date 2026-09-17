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
 addListener(deviceUUID: device
 
 */


import Foundation
import CoreBluetooth

public class XvBluetooth {
    
    //vars
    private var listeners:[BluetoothListener] = []
    
    init() {}
    
    //hard reset
    public func reset(){
        for listener in listeners {
            listener.reset()
        }
    }
    
    public func addListener(
        observer:XvBluetoothDelegate,
        deviceUUID:CBUUID?,
        serviceUUID:CBUUID?){
            
            print("XvBluetooth: addListener for device:", deviceUUID as Any)
            
            //is listener for this object already loaded?
            var alreadyLoaded:Bool = false
            for listener in listeners {
                if (listener.deviceUUID == deviceUUID) {
                    alreadyLoaded = true
                }
            }
            
            //if not, load it
            if (!alreadyLoaded) {
                let listener:BluetoothListener = BluetoothListener(
                    observer: observer,
                    deviceUUID: deviceUUID,
                    serviceUUID: serviceUUID
                )
                listeners.append(listener)
            } else {
                print("XvBluetooth: Listener already loaded for device:", deviceUUID as Any)
            }
    }

    public func removeAllListeners(){
        //dropping the listeners also drops their central managers, so anything that
        //calls this has to start() again before the next scan
        print("XvBluetooth: Removing all listeners (was", listeners.count, ")")
        listeners = []
    }
    
    public func connect(){

        /* An empty listener list means connect() does nothing at all, and used to do
         it silently: no scan, no central manager, no state callback, and so a UI stuck
         on "unknown" with no log line to explain it. That is a caller bug (connect
         before start), so say so rather than returning quietly. */
        guard !listeners.isEmpty else {
            print("XvBluetooth: Error: connect() called with no listeners. Nothing will scan. Call start() first.")
            return
        }

        print("XvBluetooth: Connect,", listeners.count, "listener(s)")

        for listener in listeners {
            
            //the the device ID is valid, print it
            if (listener.deviceUUID != nil) {
                print("XvBluetooth: Attempt connection to", listener.deviceUUID!)
                listener.delegate?.isAttemptingConnection()
                
            } else if (listener.deviceUUID == nil) {
                //if not, alert user that a scan of all nearby devices will occur
                print("XvBluetooth: Scanning for all nearby Bluetooth devices")
            }
            
            listener.connect()
        }
    }
    
    public func disconnect(){
        
        //print("XvBluetooth: Disconnect")
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



