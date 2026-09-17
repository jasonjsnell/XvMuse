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
    func didReceiveBluetoothState(_ bluetoothState: XvMuseBluetoothState, message: String)
}

//PUBLIC ON PURPOSE, despite the folder name: sibling Xv projects import
//this directly. Narrowing it would break them. See the access-level note
//in XvMuse.swift.
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
    
    /* Whether a listener (and therefore a CBCentralManager) currently exists.

     start() is the only thing that creates one, and stop() throws it away. Anything
     that scans without one does nothing at all, so connect() checks this rather than
     trusting the caller to have sequenced start() correctly. */
    private var isStarted:Bool = false

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

        print("MuseBluetooth: Start: add listener for device:",
              deviceID?.uuidString ?? "none (scan for any Muse)")

        //add bluetooth listeners
        bluetooth.addListener(
            observer: self,
            deviceUUID: deviceID,
            serviceUUID: XvMuseConstants.SERVICE_ID
        )

        isStarted = true
    }

    func stop(){
        print("MuseBluetooth: Stop")
        bluetooth.removeAllListeners()
        isStarted = false
    }
    
    
    //MARK: - Updates from the Muse headband via Bluetooth -
    public func update(bluetoothStateDescription: String, rawState: CBManagerState) {
        let bluetoothState = XvMuseBluetoothState(managerState: rawState)

        /* Logged on the way up as well as at the source, because the two lines answer
         different questions. The BLUETOOTH: line says CoreBluetooth reported a state.
         This one says the state cleared the framework boundary and is on its way to the
         app. If the first appears without the second, the delegate chain is broken. */
        if (debug){
            print("MuseBluetooth: Passing state up:",
                  BluetoothUtils.shortName(forState: rawState),
                  "| delegate:", delegate == nil ? "MISSING" : "set")
        }

        delegate?.didReceiveBluetoothState(bluetoothState, message: bluetoothStateDescription)
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
        if characteristic.uuid == XvMuseConstants.CHAR_PPG1 ||
            characteristic.uuid == XvMuseConstants.CHAR_PPG2 ||
            characteristic.uuid == XvMuseConstants.CHAR_PPG3 {
            print("MuseBluetooth: Found PPG characteristic")
            delegate?.discoveredPPG()
        }
        if (characteristic.uuid == XvMuseConstants.CHAR_ATHENA_MAIN){
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
    private var lastStatusPollTime:Date = Date()
    private let STATUS_POLL_INTERVAL:TimeInterval = 12.0

    //set when XvMuse routes an Athena through athenaInitializeAndStart; decides which
    //keep-alive command the poll above sends
    private var isAthena:Bool = false

    /* Timestamp of the last control write, exposed so a diagnostic can test whether EEG noise
     spikes are phase-locked to our own BLE chatter. Reading the reply is not good enough for that:
     the reply lands an unknown interval after the write, and its log line interleaves with prints
     from other queues, so relative print order says nothing about actual timing. */
    public internal(set) static var lastControlCommandSentTime: TimeInterval = 0
    
    public func received(valueFromCharacteristic: CBCharacteristic, fromDevice: CBPeripheral) {
        //print("XvMuse: Received value:", valueFromCharacteristic)
        
        delegate?.parse(bluetoothCharacteristic: valueFromCharacteristic)

        /* Keep-alive, timed rather than counted (the old per-500-notifications counter fired
         every ~3 s at real streaming rates, not the ~12 s it claimed).

         WHICH COMMAND depends on the device, and the difference is measured, not theoretical:

         Athena gets controlStatus(), because its firmware (3.1.29) dropped the streamed battery
         subpacket — the status reply's "bp" field is the only battery source it has. Its radio
         handles the chatter fine.

         Legacy Muse 2 / Muse S get keepAlive(). They stream battery on CHAR_BATTERY unprompted,
         so they never needed the status poll at all — and on the Muse 2 the poll was actively
         harmful. The status reply is a long JSON split across many notification packets, and an
         onboarding diagnostic showed EEG noise spikes phase-locked to the write (0.43 s after it,
         sd 0.07 s, at exactly the poll interval) with PPG dropouts in the same window: the reply
         burst congests the older radio and corrupts sensor packets in flight. keepAlive's reply
         is a single tiny packet.

         If streaming ever stalls after this change, shorten this interval first. */
        let now = Date()
        if now.timeIntervalSince(lastStatusPollTime) >= STATUS_POLL_INTERVAL {
            lastStatusPollTime = now
            if isAthena {
                controlStatus()
            } else {
                keepAlive()
            }
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
    
    /* Attempts to connect to the device.

     THE START IS NOT OPTIONAL, and it used to be easy to skip. A central manager only
     exists after start(), and start() had exactly one caller: the init, guarded by
     startBluetoothImmediately. Any app passing false for that flag (Odyssey-iOS does,
     to hold the iOS permission prompt back until the connect screen) reached this
     method with an empty listener list and scanned nothing, with no error anywhere —
     the UI simply sat on "unknown" forever, because "unknown" is the initial value of
     a state that nothing was ever going to update.

     Starting here makes the deferred case work the same as the immediate one, and also
     covers the second path into the same hole: stop() drops the listeners, so any
     connect() after a stop() had the identical problem. */
    public func connect(){

        if !isStarted {
            print("MuseBluetooth: connect() with no listener; starting Bluetooth now")
            start()
        }

        bluetooth.connect()
    }
    
    public func disconnect(){
        bluetooth.disconnect()
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
        case XvMuseConstants.PRESET_51:
            presetHex = XvMuseConstants.P51_HEX
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
    
    // MARK: - Athena control (text protocol)
    
    // Serial queue for scheduling Athena text commands with delays
    private let athenaCommandQueue = DispatchQueue(label: "MuseBluetooth.AthenaCommands")

    /*
     Presets                            EEG     Optics    Red LED
     p20, p21, p50, p51, p60, p61        4        —         off
     p1035                               4        4         dim
     p1045, p1046                        8        4         dim
     p1044, p1043, p1034,                8        8        bright
     p1041, p1042                        8        16       bright
     */
    
    public func athenaInitializeAndStart(preset: String = "p1035") {
        isAthena = true
        
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

            MuseBluetooth.lastControlCommandSentTime = Date().timeIntervalSinceReferenceDate

            bluetooth.write(
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
