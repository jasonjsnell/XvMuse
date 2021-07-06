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
public protocol MuseBluetoothObserver:AnyObject {
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
        
        //connection time counter
        timeFormatter = DateComponentsFormatter()
        timeFormatter.allowedUnits = [.second]
        
        //bluetooth
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
    
    
    //MARK: - Updates from the Muse headband via Bluetooth -
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
            print("Discovered", nearbyDevice.name!, "headband with ID:", nearbyDevice.identifier.uuidString)
            print("")
            print("Use the line below to intialize the XvMuse framework with this Muse device.")
            print("")
            print("let muse:XvMuse = XvMuse(deviceID: \"\(nearbyDevice.identifier.uuidString)\")")
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
    fileprivate var connectionStartTime:Date = Date()
    fileprivate let timeFormatter:DateComponentsFormatter
    fileprivate let RECONNECTION_SIGNAL_INTERVAL:Int = 500
    
    public func received(valueFromCharacteristic: CBCharacteristic, fromDevice: CBPeripheral) {
        //print("XvMuse: Received value:", valueFromCharacteristic)
        
        observer?.parse(bluetoothCharacteristic: valueFromCharacteristic)
        
        
        //up the counter
        connectionCounter += 1
        if (connectionCounter > RECONNECTION_SIGNAL_INTERVAL){
            keepAlive()
            print("Connection time:", timeFormatter.string(from: connectionStartTime, to: Date())!)
            connectionCounter = 0
        }
        
    }
    
    public func didLoseConnection() {
        observer?.didLoseConnection()
        connect() //reconnect immediately
    }
    
    public func didDisconnect() {
        observer?.didDisconnect()
    }
    
    //MARK: - Send commands to the Muse headband -
    
    //attempts to connect to device. Run this once the bluetooth has had a few seconds to initialize
    public func connect(){
        XvBluetooth.sharedInstance.connect()
    }
    
    public func disconnect(){
        XvBluetooth.sharedInstance.disconnect()
    }
    
    //start streaming data
    public func startStreaming(){
        
        //reset connection time
        connectionStartTime = Date()
        
        let data:Data = Data(_:XvMuseConstants.CMND_RESUME)
        sendControlCommand(data: data)
    }
    
    //pause the stream
    public func pauseStreaming(){
        
        let data:Data = Data(_:XvMuseConstants.CMND_HALT)
        sendControlCommand(data: data)
    }
    
    //device init
    public func versionHandshake(){
        
        //device info is the way to set the command protocol to V2
        let data:Data = Data(_:XvMuseConstants.CMND_VERSION_HANDSHAKE)
        sendControlCommand(data: data)
    }
    
    public func set(hostPlatform:UInt8){
        
        var hostHex:UInt8 = XvMuseConstants.HOST_PLATFORM_MAC_HEX
        
        switch hostPlatform {
        
        case XvMuseConstants.HOST_PLATFORM_IOS,
             XvMuseConstants.HOST_PLATFORM_IOS_HEX:
            print("MuseBluetooth: Set Host Platform to iOS")
            hostHex = XvMuseConstants.HOST_PLATFORM_IOS_HEX
        case XvMuseConstants.HOST_PLATFORM_ANDROID,
             XvMuseConstants.HOST_PLATFORM_ANDROID_HEX:
            print("MuseBluetooth: Set Host Platform to Android")
            hostHex = XvMuseConstants.HOST_PLATFORM_ANDROID_HEX
        case XvMuseConstants.HOST_PLATFORM_WINDOWS,
             XvMuseConstants.HOST_PLATFORM_WINDOWS_HEX:
            print("MuseBluetooth: Set Host Platform to Windows")
            hostHex = XvMuseConstants.HOST_PLATFORM_WINDOWS_HEX
        case XvMuseConstants.HOST_PLATFORM_MAC,
             XvMuseConstants.HOST_PLATFORM_MAC_HEX:
            print("MuseBluetooth: Set Host Platform to Mac")
            hostHex = XvMuseConstants.HOST_PLATFORM_MAC_HEX
        case XvMuseConstants.HOST_PLATFORM_LINUX,
             XvMuseConstants.HOST_PLATFORM_LINUX_HEX:
            print("MuseBluetooth: Set Host Platform to Linux")
            hostHex = XvMuseConstants.HOST_PLATFORM_LINUX_HEX
        default:
            print("MuseBluetooth: Error: Host Platform ID", hostPlatform)
            break
        }
    
        var hostPlatformCmnd:[UInt8] = XvMuseConstants.CMND_HOST_PLATFORM_PRE
        hostPlatformCmnd.append(hostHex)
        hostPlatformCmnd.append(XvMuseConstants.CMND_HOST_PLATFORM_POST)
        
        let data:Data = Data(_:hostPlatformCmnd)
        sendControlCommand(data: data)
    }
    
    public func set(preset:UInt8){
        
        print("MuseBluetooth: Set Preset to", preset)
        
        var presetHex:[UInt8] = XvMuseConstants.P21_HEX //default
        
        switch preset {
        
        case XvMuseConstants.PRESET_20:
            presetHex = XvMuseConstants.P20_HEX
        case XvMuseConstants.PRESET_21:
            presetHex = XvMuseConstants.P21_HEX
        case XvMuseConstants.PRESET_22:
            presetHex = XvMuseConstants.P22_HEX
        case XvMuseConstants.PRESET_23:
            presetHex = XvMuseConstants.P23_HEX
        default:
            print("MuseBluetooth: Error: Preset ID", preset)
            break
        }
        
        var presetCmnd:[UInt8] = XvMuseConstants.CMND_PRESET_PRE
        presetCmnd += presetHex
        presetCmnd.append(XvMuseConstants.CMND_PRESET_POST)
        
        let data:Data = Data(_:presetCmnd)
        sendControlCommand(data: data)
    }
    
    public func resetMuse(){
        print("MuseBluetooth: Reset Muse")
        let data:Data = Data(_:XvMuseConstants.CMND_RESET)
        sendControlCommand(data: data)
    }
    
    
    
    //get status, including battery power (bp)
    public func controlStatus(){
        
        let data:Data = Data(_:XvMuseConstants.CMND_STATUS)
        sendControlCommand(data: data)
    }
    
    //internal
    internal func keepAlive(){
        let data:Data = Data(_:XvMuseConstants.CMND_KEEP)
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
