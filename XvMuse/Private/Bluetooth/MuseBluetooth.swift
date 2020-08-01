//
//  MuseBluetooth.swift
//  XvMuse
//
//  Created by Jason Snell on 7/2/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation
import CoreBluetooth

//the observer receives the values coming in from bluetooth
public protocol MuseBluetoothObserver:class {
    func parse(bluetoothCharacteristic: CBCharacteristic)
    
    //steps of connecting, disconnecting
    func isConnecting()
    func didConnect()
    func didDisconnect()
    func didLoseConnection()
}

public class MuseBluetooth:XvBluetoothObserver {
    
    public var observer:MuseBluetoothObserver?
    fileprivate var deviceID:CBUUID?
    
    public init(deviceCBUUID:CBUUID?) {
        
        deviceID = deviceCBUUID
        
        //add bluetooth listeners
        XvBluetooth.sharedInstance.addListener(
            observer: self,
            deviceUUID: deviceCBUUID,
            serviceUUID: XvMuseConstants.SERVICE_ID,
            characteristicsUUIDs: [
                XvMuseConstants.CHAR_CONTROL,
                XvMuseConstants.CHAR_TP9,
                XvMuseConstants.CHAR_AF7,
                XvMuseConstants.CHAR_AF8,
                XvMuseConstants.CHAR_TP10,
                //XvMuseConstants.CHAR_RAUX,
                //XvMuseConstants.CHAR_GYRO,
                XvMuseConstants.CHAR_ACCEL,
                XvMuseConstants.CHAR_BATTERY,
                XvMuseConstants.CHAR_PPG1,
                XvMuseConstants.CHAR_PPG2,
                XvMuseConstants.CHAR_PPG3
            ]
        )
    }
    
    
    //MARK: Updates from the Muse headband via Bluetooth
    public func update(state: String) {
        print("XvMuse: State:", state)
    }
    
    public func discovered(targetDevice: CBPeripheral) {
        print("XvMuse: Discovered target device:", targetDevice.identifier.uuidString)
        observer?.isConnecting()
    }
    
    public func discovered(nearbyDevice: CBPeripheral) {
        
        //does the nearby device have a name with "Muse" in the string?
        if nearbyDevice.name?.contains("Muse") ?? false {
            
            //if so, print results and init instructions
            print("")
            print("----------------------------")
            print("")
            print("Discovered", nearbyDevice.name!, "headband with CBUUID:", nearbyDevice.identifier.uuidString)
            print("")
            print("Use the line below to intialize the XvMuse framework with this Muse device.")
            print("")
            print("let muse:XvMuse = XvMuse(deviceCBUUID: CBUUID(string: \"\(nearbyDevice.identifier.uuidString)\"))")
            print("")
            print("----------------------------")
            print("")
            
        }
        print("Discovered non-Muse Bluetooth device:", nearbyDevice.identifier.uuidString)
        
    }
    
    public func discovered(service: CBService) {
        print("XvMuse: Discovered service:", service.uuid)
        observer?.didConnect()
    }
    
    public func discovered(characteristic: CBCharacteristic) {
        print("XvMuse: Discovered char:", characteristic.uuid.uuidString, characteristic.properties.rawValue)
    }
    
    //this is the bridge between the XvBluetooth framework and this class
    
    //sends "K" / "Keep Alive" command
    fileprivate var connectionCounter:Int = 0
    fileprivate let RECONNECTION_SIGNAL_INTERVAL:Int = 5
    
    public func received(valueFromCharacteristic: CBCharacteristic, fromDevice: CBPeripheral) {
        //print("XvMuse: Received value:", valueFromCharacteristic)
        
        observer?.parse(bluetoothCharacteristic: valueFromCharacteristic)
        
        //up the counter
        connectionCounter += 1
        if (connectionCounter > RECONNECTION_SIGNAL_INTERVAL){
            keepAlive()
            connectionCounter = 0
        }
    }
    
    public func didLoseConnection() {
        observer?.didLoseConnection()
    }
    
    public func didDisconnect() {
        observer?.didDisconnect()
    }
    
    //MARK: Send commands to the Muse headband
    
    //attempts to connect to device. Run this once the bluetooth has had a few seconds to initialize
    public func connect(){
        XvBluetooth.sharedInstance.connect()
    }
    
    public func disconnect(){
        XvBluetooth.sharedInstance.disconnect()
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
        
        if (deviceID != nil) {
            
            XvBluetooth.sharedInstance.write(
                data:data,
                toDeviceWithID: deviceID!,
                forCharacteristicWithID: XvMuseConstants.CHAR_CONTROL,
                withType: .withoutResponse
            )
            
        } else {
            print("MuseBluetooth: Error: Attempting to send a control command to a nil device")
        }
    }
}
