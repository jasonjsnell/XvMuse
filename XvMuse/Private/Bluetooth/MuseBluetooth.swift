//
//  MuseBluetooth.swift
//  XvMuse
//
//  Created by Jason Snell on 7/2/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation
import CoreBluetooth
import ExternalAccessory

//the observer receives the values coming in from bluetooth
internal protocol MuseBluetoothObserver:AnyObject {
    
    //characteristics
    func discoveredPPG()
    func discoveredAthena()
    func parse(bluetoothCharacteristic: CBCharacteristic)
    
    //steps of connecting, disconnecting
    func isConnecting()
    func didConnect()
    func didDisconnect()
    func didLoseConnection()
    func isAttemptingConnection()
    func didFindNearby(muses:[CBPeripheral])
}

public class MuseBluetooth:XvBluetoothDelegate {
    
    private let bluetooth:XvBluetooth
    internal var delegate:MuseBluetoothObserver?
    private var deviceID:CBUUID?
    
   
    private let debug:Bool = true
    
    public init(deviceCBUUID:CBUUID?) {
        
        //connection time counter
        timeFormatter = DateComponentsFormatter()
        timeFormatter.allowedUnits = [.second]
        
        //bluetooth
        deviceID = deviceCBUUID
        
        bluetooth = XvBluetooth()
    }
    
    //hard reset
    internal func reset(){
        deviceID = nil
        bluetooth.reset()
    }
    
    //selected in user interface
    internal func load(muse:CBPeripheral) {
        deviceID = CBUUID(string: muse.identifier.uuidString)
        start()
    }
    
    internal func start(){
        
        nearbyMuses = []
    
        if (debug){
            print("MuseBluetooth: Start: Add listeners")
        }
        
        //add bluetooth listeners
        bluetooth.addListener(
            observer: self,
            deviceUUID: deviceID,
            serviceUUID: MuseConstants.SERVICE_ID
        )
    }
    
    func stop(){
        bluetooth.removeAllListeners()
    }
    
    
    //MARK: - Updates from the Muse headband via Bluetooth -
    public func update(state: String) {
        //print("XvMuse: State:", state)
    }
    
    public func discovered(targetDevice: CBPeripheral) {
        if (targetDevice.identifier.uuidString == deviceID?.uuidString) {
            if (debug){
                print("XvMuse: Discovered target device:", targetDevice.identifier.uuidString)
            }
            delegate?.isConnecting()
        } else {
            print("XvMuse: Discovered device:", targetDevice.identifier.uuidString)
        }
    }
    
    var nearbyMuses:[CBPeripheral] = []
    public func discovered(nearbyDevice: CBPeripheral) {
        
//        if (debug){
//            print("MuseBluetooth: nearbyDevice", nearbyDevice)
//        }
        
        //does the nearby device have a name with "Muse" in the string?
        if nearbyDevice.name?.contains("Muse") ?? false {
            
            if (debug){
                print("MuseBluetooth: Discovered", nearbyDevice.name!, "nearby headband with ID:", nearbyDevice.identifier.uuidString)
            }
            //stop the search
            //stop()
            
            //send ID back to top so it can be loaded from scratch into system
            if !nearbyMuses.contains(nearbyDevice) {
                nearbyMuses.append(nearbyDevice)
            }
            
            delegate?.didFindNearby(muses: nearbyMuses)
            if (debug){
                print("MuseBluetooth: nearby Muses", nearbyMuses)
            }
            
            //if so, print results and init instructions
//            if (debug){
//                print("")
//                print("----------------------------")
//                print("")
//                print("Discovered", nearbyDevice.name!, "headband with ID:", nearbyDevice.identifier.uuidString)
//                print("")
//                print("Use the line below to intialize the XvMuse framework with this Muse device.")
//                print("")
//                print("let muse:XvMuse = XvMuse(deviceID: \"\(nearbyDevice.identifier.uuidString)\")")
//                print("")
//                print("----------------------------")
//                print("")
//            }
        }
//        if (debug) {
//            print("D...", nearbyDevice.name ?? "Device with no name")
//            print("Discovered non-Muse Bluetooth device:", nearbyDevice.name ?? "No name", nearbyDevice.identifier.uuidString)
//            print("Nearby device", nearbyDevice)
//            let name:String = nearbyDevice.name ?? ""
//            if (name != "") {
//                print("Discovered device:", nearbyDevice.name ?? "No name", nearbyDevice.identifier.uuidString)
//            }
//        }
    }
    
    
    public func discovered(service: CBService) {
        print("XvMuse: Discovered service:", service.uuid)
        delegate?.didConnect()
    }
    
    public func discovered(characteristic: CBCharacteristic) {
        print("XvMuse: Discovered char:", characteristic.uuid.uuidString, characteristic.properties.rawValue)
        //check for specific sensors
        if (characteristic.uuid == MuseConstants.CHAR_PPG2){
            print("MuseBluetooth: Found PPG characteristic")
            delegate?.discoveredPPG()
        }
        if (characteristic.uuid == MuseConstants.CHAR_ATHENA_MAIN){
            print("MuseBluetooth: Found Athena characteristic")
            delegate?.discoveredAthena()
        }
    }
    
    //this is the bridge between the XvBluetooth framework and this class
    
    //sends "K" / "Keep Alive" command
    private var connectionCounter:Int = 0
    private var connectionStartTime:Date = Date()
    private let timeFormatter:DateComponentsFormatter
    private let RECONNECTION_SIGNAL_INTERVAL:Int = 500
    
    public func received(valueFromCharacteristic: CBCharacteristic, fromDevice: CBPeripheral) {
        //print("XvMuse: Received value:", valueFromCharacteristic)
        
        delegate?.parse(bluetoothCharacteristic: valueFromCharacteristic)
        
        //up the counter
        connectionCounter += 1
        if (connectionCounter > RECONNECTION_SIGNAL_INTERVAL){
            keepAlive()
            //print("Connection time:", timeFormatter.string(from: connectionStartTime, to: Date())!)
            connectionCounter = 0
        }
        
    }
    
    public func isAttemptingConnection() {
        delegate?.isAttemptingConnection()
    }
    
    public func didLoseConnection() {
        print("XvMuse: didLoseConnection")
        delegate?.didLoseConnection()
        connect() //reconnect immediately
    }
    
    public func didDisconnect() {
        delegate?.didDisconnect()
    }
    
    //MARK: - Send commands to the Muse headband -
    
    //attempts to connect to device. Run this once the bluetooth has had a few seconds to initialize
    public func connect(){
        bluetooth.connect()
    }
    
    public func disconnect(){
        bluetooth.disconnect()
    }
    
    //start streaming data
    public func startStreaming(){
        
        //reset connection time
        connectionStartTime = Date()
        
        let data:Data = Data(_:MuseConstants.CMND_RESUME)
        sendControlCommand(data: data)
    }
    
    //pause the stream
    public func pauseStreaming(){
        
        let data:Data = Data(_:MuseConstants.CMND_HALT)
        sendControlCommand(data: data)
    }
    
    //device init
    public func versionHandshake(){
        
        //device info is the way to set the command protocol to V2
        let data:Data = Data(_:MuseConstants.CMND_VERSION_HANDSHAKE)
        sendControlCommand(data: data)
    }
    
    public func set(hostPlatform:UInt8){
        
        var hostHex:UInt8 = MuseConstants.HOST_PLATFORM_MAC_HEX
        
        switch hostPlatform {
        
        case MuseConstants.HOST_PLATFORM_IOS,
             MuseConstants.HOST_PLATFORM_IOS_HEX:
            print("MuseBluetooth: Set Host Platform to iOS")
            hostHex = MuseConstants.HOST_PLATFORM_IOS_HEX
        case MuseConstants.HOST_PLATFORM_ANDROID,
             MuseConstants.HOST_PLATFORM_ANDROID_HEX:
            print("MuseBluetooth: Set Host Platform to Android")
            hostHex = MuseConstants.HOST_PLATFORM_ANDROID_HEX
        case MuseConstants.HOST_PLATFORM_WINDOWS,
             MuseConstants.HOST_PLATFORM_WINDOWS_HEX:
            print("MuseBluetooth: Set Host Platform to Windows")
            hostHex = MuseConstants.HOST_PLATFORM_WINDOWS_HEX
        case MuseConstants.HOST_PLATFORM_MAC,
             MuseConstants.HOST_PLATFORM_MAC_HEX:
            print("MuseBluetooth: Set Host Platform to Mac")
            hostHex = MuseConstants.HOST_PLATFORM_MAC_HEX
        case MuseConstants.HOST_PLATFORM_LINUX,
             MuseConstants.HOST_PLATFORM_LINUX_HEX:
            print("MuseBluetooth: Set Host Platform to Linux")
            hostHex = MuseConstants.HOST_PLATFORM_LINUX_HEX
        default:
            print("MuseBluetooth: Error: Host Platform ID", hostPlatform)
            break
        }
    
        var hostPlatformCmnd:[UInt8] = MuseConstants.CMND_HOST_PLATFORM_PRE
        hostPlatformCmnd.append(hostHex)
        hostPlatformCmnd.append(MuseConstants.CMND_HOST_PLATFORM_POST)
        
        let data:Data = Data(_:hostPlatformCmnd)
        sendControlCommand(data: data)
    }
    
    public func set(preset:UInt8){
        
        print("MuseBluetooth: Set Preset to", preset)
        
        var presetHex:[UInt8] = MuseConstants.P21_HEX //default
        
        switch preset {
        
        case MuseConstants.PRESET_20:
            presetHex = MuseConstants.P20_HEX
        case MuseConstants.PRESET_21:
            presetHex = MuseConstants.P21_HEX
        case MuseConstants.PRESET_22:
            presetHex = MuseConstants.P22_HEX
        case MuseConstants.PRESET_23:
            presetHex = MuseConstants.P23_HEX
        case MuseConstants.PRESET_51:
            presetHex = MuseConstants.P51_HEX
        default:
            print("MuseBluetooth: Error: Preset ID", preset)
            break
        }
        
        var presetCmnd:[UInt8] = MuseConstants.CMND_PRESET_PRE
        presetCmnd += presetHex
        presetCmnd.append(MuseConstants.CMND_PRESET_POST)
        
        let data:Data = Data(_:presetCmnd)
        sendControlCommand(data: data)
    }
    
    public func resetMuse(){
        print("MuseBluetooth: Reset Muse")
        let data:Data = Data(_:MuseConstants.CMND_RESET)
        sendControlCommand(data: data)
    }
    
    
    
    //get status, including battery power (bp)
    public func controlStatus(){
        
        let data:Data = Data(_:MuseConstants.CMND_STATUS)
        sendControlCommand(data: data)
    }
    
    //internal
    internal func keepAlive(){
        let data:Data = Data(_:MuseConstants.CMND_KEEP)
        sendControlCommand(data: data)
    }
    
    // MARK: - Athena control (text protocol)
    
    // Serial queue for scheduling Athena text commands with delays
    private let athenaCommandQueue = DispatchQueue(label: "MuseBluetooth.AthenaCommands")

    public func athenaInitializeAndStart(preset: String = "p1041") {
        
        func enqueueToken(_ token: String, delay: TimeInterval) {
            athenaCommandQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self,
                      let data = try? self.makeAthenaCommand(token) else { return }
                self.sendControlCommand(data: data)
            }
        }
        
        var delay: TimeInterval = 0.0
        
        // Version/status handshake (best-effort)
        enqueueToken("v6", delay: delay)
        delay += 0.2
        enqueueToken("s", delay: delay)
        delay += 0.2
        
        // Halt / reset
        enqueueToken("h", delay: delay)
        delay += 0.2
        
        // Apply preset
        enqueueToken(preset, delay: delay)
        delay += 0.2
        
        // Status again (optional)
        enqueueToken("s", delay: delay)
        delay += 0.2
        
        // Start streaming: dc001 sent twice
        enqueueToken("dc001", delay: delay)
        delay += 0.05
        enqueueToken("dc001", delay: delay)
        delay += 0.1
        
        // Low-latency mode (optional)
        enqueueToken("L1", delay: delay)
        delay += 0.3
        
        // Final status (optional)
        enqueueToken("s", delay: delay)
        // Python code waits another 0.2s here, but we don't need to enqueue anything else.
    }

    public func athenaStartStreaming() {
        guard let dc = try? makeAthenaCommand("dc001") else { return }
        sendControlCommand(data: dc)
        sendControlCommand(data: dc)
    }

    public func athenaStopStreaming() {
        guard let h = try? makeAthenaCommand("h") else { return }
        sendControlCommand(data: h)
    }

    public func athenaStatus() {
        guard let s = try? makeAthenaCommand("s") else { return }
        sendControlCommand(data: s)
    }

    private enum MuseCommandError: Error {
        case invalidToken
        case tooLong
    }

    private func makeAthenaCommand(_ token: String) throws -> Data {
        guard !token.isEmpty, let payload = (token + "\n").data(using: .ascii) else {
            throw MuseCommandError.invalidToken
        }
        guard payload.count <= 255 else {
            throw MuseCommandError.tooLong
        }
        var data = Data()
        data.append(UInt8(payload.count))
        data.append(payload)
        return data
    }

    
    //MARK: send control command
    private func sendControlCommand(data:Data) {
        
        if (deviceID != nil) {
            
            bluetooth.write(
                data:data,
                toDeviceWithID: deviceID!,
                forCharacteristicWithID: MuseConstants.CHAR_CONTROL,
                withType: .withoutResponse
            )
            
        } else {
            print("MuseBluetooth: Error: Attempting to send a control command to a nil device")
        }
    }
}
