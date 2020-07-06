//
//  MuseBluetooth.swift
//  XvMuse
//
//  Created by Jason Snell on 7/2/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation
import CoreBluetooth
import XvBluetooth

//the observer receives the values coming in from bluetooth
public protocol MuseBluetoothObserver:class {
    func parse(bluetoothCharacteristic: CBCharacteristic)
}

public class MuseBluetooth:XvBluetoothObserver {
    
    public var observer:MuseBluetoothObserver?
    
    public init() {
        
        //add bluetooth listeners
        XvBluetooth.sharedInstance.addListener(
            observer: self,
            deviceUUID: XvMuseConstants.DEVICE_ID,
            serviceUUID: XvMuseConstants.SERVICE_ID,
            characteristicsUUIDs: [
                XvMuseConstants.CHAR_CONTROL,
                XvMuseConstants.CHAR_TP9,
                XvMuseConstants.CHAR_AF7,
                XvMuseConstants.CHAR_AF8,
                XvMuseConstants.CHAR_TP10,
                //XvMuseConstants.CHAR_RAUX,
                //XvMuseConstants.CHAR_GYRO,
                //XvMuseConstants.CHAR_ACCEL,
                //XvMuseConstants.CHAR_BATTERY,
                //XvMuseConstants.CHAR_PPG1,
                //XvMuseConstants.CHAR_PPG2,
                //XvMuseConstants.CHAR_PPG3
            ]
        )
        
    }
    
    
    //MARK: Updates from the Muse headband via Bluetooth
    public func update(state: String) {
        print("MUSE: State:", state)
    }
    
    public func discovered(device: CBPeripheral) {
        print("MUSE: Discovered device:", device.identifier.uuidString, device.name ?? "No Name")
    }
    
    public func discovered(service: CBService) {
        print("MUSE: Discovered service:", service.uuid)
    }
    
    public func discovered(characteristic: CBCharacteristic) {
        print("MUSE: Discovered char:", characteristic.uuid.uuidString, characteristic.properties.rawValue)
    }
    
    //this is the bridge between the XvBluetooth framework and this class
    public func received(valueFromCharacteristic: CBCharacteristic, fromDevice: CBPeripheral) {
        //print("MUSE: Received value:", valueFromCharacteristic)
        observer?.parse(bluetoothCharacteristic: valueFromCharacteristic)
    }
    
    
    //MARK: Send commands to the Muse headband
    
    //attempts to connect to device. Run this once the bluetooth has had a few seconds to initialize
    public func connect(){
        XvBluetooth.sharedInstance.connect()
    }
    
    //start streaming data
    public func startStreaming(){
        
        let data:Data = Data(_:XvMuseConstants.CMND_RESUME)
        sendControlCommand(data: data)
    }
    
    //pause the stream
    public func pauseStreaming(){
        
        let data:Data = Data(_:XvMuseConstants.CMND_STOP)
        sendControlCommand(data: data)
    }
    
    public func keepAlive(){
        
        let data:Data = Data(_:XvMuseConstants.CMND_KEEP)
        sendControlCommand(data: data)
    }
    
    //get device info
    public func getDeviceInfo(){
        
        let data:Data = Data(_:XvMuseConstants.CMND_DEVICE)
        sendControlCommand(data: data)
    }
    
    //get status, including battery power (bp)
    public func getControlStatus(){
        
        let data:Data = Data(_:XvMuseConstants.CMND_STATUS)
        sendControlCommand(data: data)
    }
    
    //sub routine
    fileprivate func sendControlCommand(data:Data) {
        
        XvBluetooth.sharedInstance.write(
            data:data,
            toDeviceWithID: XvMuseConstants.DEVICE_ID,
            forCharacteristicWithID: XvMuseConstants.CHAR_CONTROL,
            withType: .withoutResponse
        )
    }
    
    
}
