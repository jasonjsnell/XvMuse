//
//  XvMuse.swift
//  XvMuse
//
//  Created by Jason Snell on 6/14/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//
// UInt8  255
// UInt16 65535
// UInt32 4294967295

import Foundation
import CoreBluetooth
import XvSensors

//another object or a view controller that can listen to this class's updates
public protocol XvMuseDelegate:AnyObject {
    
    //brainwaves
    //Absolute band power density (clinical): average PSD (µV²/Hz) per band.
//    func didReceiveAbsolute(delta: Double, theta: Double, alpha: Double, beta: Double, gamma: Double)
//
//    // Balanced bands for sonification: relative (across bands) + tilt compensation, in dB.
//    func didReceiveBalanced(delta: Double, theta: Double, alpha: Double, beta: Double, gamma: Double)
    
    //packets
    func didReceive(eegPacket:XvEEGPacket)
    
    func didReceive(ppgPacket:XvPPGPacket)
    func didReceive(ppgHeartEvent:XvPPGHeartEvent)
    
    func didReceive(accelPacket:XvAccelPacket)
    
    func didReceive(batteryPacket:XvBatteryPacket)
    
    func didReceive(commandResponse:[String:Any])
    
    //bluetooth connection updates
    func museIsAttemptingConnection()
    func museIsConnecting()
    func museDidConnect()
    func museDidDisconnect()
    func museLostConnection()
    func didFindNearby(muses: [CBPeripheral])
    
    func didReceiveAthena(opticsPacket:[Double])
    
}

//MARK: - PACKETS -
//data objects that get sent to the observer when updates come in from the headband

/* Each time the Muse headband fires off an EEG sensor update (order is: tp10 af8 tp9 af7),
the XvMuse class puts that data into MuseEEGPackets
and sends it here to create a streaming buffer, slice out epoch windows, and return Fast Fourier Transformed array of frequency data
       
       ch1     ch2     ch3     ch4  < EEG sensors tp10 af8 tp9 af7
                       ---     ---
0:00    p       p     | p |   | p | < MuseEEGPacket is one packet of a 12 sample EEG reading, index, timestamp, channel ID
0:01    p       p     | p |    ---
0:02    p       p     | p |     p
0:03    p       p     | p |     p
0:04    p       p     | p |     p
0:05    p       p     | p |     p
                       ___

                        ^ DataBuffer of streaming samples. Each channel has it's own buffer
*/

internal class MusePacket {
    
    internal var packetIndex:UInt16 = 0
    internal var sensor:Int = 0 // 0 to 4: tp10 af8 tp9 af7 aux
    internal var timestamp:Double = 0 // milliseconds since packet creation
    internal var samples:[Double] = [] // 12 samples of EEG sensor data
    
    internal init(packetIndex:UInt16, sensor:Int, timestamp:Double, samples:[Double]){
        self.packetIndex = packetIndex
        self.sensor = sensor
        self.timestamp = timestamp
        self.samples = samples
    }
}

//MARK: - EEG / PPG
internal class MuseEEGPacket:MusePacket {}
internal class MusePPGPacket:MusePacket {}

//MARK: - Battery
internal struct MuseBattery {
    internal var packetIndex:UInt16 = 0
    internal var percentage:Int16 = 0
    internal var raw:[UInt16] = []
}


//MARK: - MUSE -
public class XvMuse:MuseBluetoothObserver, ParserAthenaDelegate {
    
    
    public func didReceiveAthena(opticsPacket:[Double]){
        delegate?.didReceiveAthena(opticsPacket: opticsPacket)
    }
    //MARK: - vars

    /* Receives commands from the view controller (like keyDown), translates and sends them to the Muse, and receives data back via parse(bluetoothCharacteristic func */
    public var bluetooth:MuseBluetooth
    
    //the view controller that receives EEG, accel, PPG, etc updates
    public weak var delegate:XvMuseDelegate?
    
    //device version
    public var deviceName:XvDeviceName = .muse2
    private var majorVersion:String = "Muse"
    private var minorVersion:String = "1" //1, 2, Athena
    
    
    //MARK: - Private
    //sensor data objects
    private var _eeg:MuseEEG
    private var _testEEG:MuseEEG
    private var _ppg:MusePPG
    private var _testPPG:MusePPG
    private var _accelRaw:[Int16] = []
    private var _batteryRaw:[UInt16] = []

    //helper classes
    private let _parserLegacy:ParserLegacy = ParserLegacy() //processes 1/2/S data
    private let _parserAthena:ParserAthena = ParserAthena() //processes Athena data
    private var _fft:FFTManager = FFTManager()
    
    //grabs a timestamp when the system launches, to make timestamps easier to read
    private let _systemLaunchTime:Double = Date().timeIntervalSince1970
    
    private var deviceUUID:String?
    
    private let debug:Bool = true
    
    //matrix to store bytes from 4 sensors when recording test data
    private var eegSensorBytes: [[[UInt8]]] = Array(repeating: [], count: 4)
    private var ppgSensorBytes:[[UInt8]] = []
    public func printEEGPPGSensorBytes() {
        print("========== EEG/PPG Data Start ==========")
        for (sensorIndex, packets) in eegSensorBytes.enumerated() {
            print("EEG \(sensorIndex + 1):")
            print(packets)
            print("") // blank line between sensors
        }
        print("")
        print("PPG")
        print(ppgSensorBytes)
        print("========== EEG/PPG Data End ==========")
    }
    
    
    //MARK: - INIT -
    //default range is 0 Hz delta to 45 Hz gamma
    public init(deviceUUID:String? = nil) {
       
        if (deviceUUID == nil) {
            print("XvMuse: init with no deviceUUID")
        }
        
        //if a valid device ID string comes in, make a CBUUID for the bluetooth object
        var deviceCBUUID:CBUUID?
        
        if (deviceUUID != nil) {
            self.deviceUUID = deviceUUID //local storage
            deviceCBUUID = CBUUID(string: deviceUUID!)
        }
        
        _eeg = MuseEEG()
        _testEEG = MuseEEG()
        
        _ppg = MusePPG()
        _testPPG = MusePPG()
     
        bluetooth = MuseBluetooth(deviceCBUUID: deviceCBUUID)
        bluetooth.delegate = self
        bluetooth.start()
        
        _parserAthena.delegate = self
    }
    
    //MARK: - Device API -
    //MARK: Nearby Muses
    public func lookForNearbyMuses(){
        
        if (debug) { print("XvMuse: lookForNearbyMuses") }
        
        //reset deviceID
        deviceUUID = nil
        bluetooth.reset()
        
        //connect bluetooth again
        bluetooth.connect()
    }
    
    public func didFindNearby(muses: [CBPeripheral]) {
        //print("XvMuse: didFindNearby", muses)
        onMain { self.delegate?.didFindNearby(muses: muses) }
    }
    
    //MARK: User selects Muse
    public func userSelectedMuse(museDevice:CBPeripheral){
        
        if let museName = museDevice.name {
            
            // "Muse-66CD" -> "Muse"
            let parts = museName.split(separator: "-")
            if let firstPart = parts.first {
                majorVersion = String(firstPart)
            } else {
                // Fallback if no dash found
                majorVersion = museName
            }
            if (majorVersion == "Muse") {
                deviceName = .muse1
            } else if (majorVersion == "MuseS") {
                deviceName = .museS
            }
            print("XvMuse: Major version =", majorVersion, "| Device may be", deviceName)
        }
        
        bluetooth.stop() //stop the search
        bluetooth.load(muse: museDevice) //load user selected muse
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.bluetooth.connect()
        }
    }
    
    //MARK: Discovered sensors
    func discoveredPPG() {
        if (majorVersion == "Muse"){
            minorVersion = "2"
            deviceName = .muse2
        }
        print("XvMuse: Version:", majorVersion, minorVersion, "| Device", deviceName)
    }
    func discoveredAthena() {
        minorVersion = "Athena"
        deviceName = .museAthena
        print("XvMuse: Version:", majorVersion, minorVersion, "| Device", deviceName)
    }
    
    //MARK: Start streaming
    public func startMuse(){
        print("XvMuse: Start streaming Muse data")
        bluetooth.startStreaming()
    }
    
    
    //MARK: - DATA PROCESSING -
    internal func parse(bluetoothCharacteristic: CBCharacteristic) {
        
        processingQ.async { [weak self] in
            
            //safety checks
            guard let self = self else { return }
            guard let _data:Data = bluetoothCharacteristic.value else { return }
            
            //MARK: route Athena data to parser
            // Special-case Athena main stream BEFORE legacy parsing
            if bluetoothCharacteristic.uuid == MuseConstants.CHAR_ATHENA_MAIN {
                let bytes = [UInt8](_data)
                let systemTimestamp = Date().timeIntervalSince1970 - self._systemLaunchTime
                self._parserAthena.handleAthenaMain(bytes: bytes, systemTimestamp: systemTimestamp)
                return
            }
        
            //MARK: Legacy processing (Muse 1/2/S)
            var bytes:[UInt8] = [UInt8](_data) //move into an array
            
            let packetIndex:UInt16 = _parserLegacy.getPacketIndex(fromBytes: bytes) //remove and store package index
            bytes.removeFirst(2) //2 bytes is 1 UInt16 package index

            //get a current timestamp, and substract the system launch time so it's a smaller, more readable number
            let timestamp:Double = Date().timeIntervalSince1970 - _systemLaunchTime
            
            // local func to make EEG packet from the above variables
            
            func _makeEEGPacket(i:Int) -> MuseEEGPacket {
                
                //uncomment to store bytes for test data recording
                //and wire a key P command to fire off printEEGPPGSensorBytes() at the end
                //eegSensorBytes[i].append(bytes)
                
                //to see a single packet for testing
                //if (i == 2) { print(bytes, ",") }
                
                return MuseEEGPacket(
                    packetIndex: packetIndex,
                    sensor: i,
                    timestamp: timestamp,
                    samples: _parserLegacy.getEEGSamples(from: bytes))
            }
            
            // local func to make PPG packet from the above variables
            
            func _makePPGPacket() -> MusePPGPacket {
                
                //uncomment to store bytes for test data recording
                //and wire a key P command to fire off printEEGPPGSensorBytes() at the end
                //ppgSensorBytes.append(bytes)
                
                //print off a single packet for testing
                //print(bytes, ",")
                
                //delegate?.didReceive(ppgPacket: packet) //send to observer in case someone wants to do their own PPG processing
                
                return MusePPGPacket(
                    packetIndex: packetIndex,
                    sensor: 1, // only use sensor 1 (not 0 or 2)
                    timestamp: timestamp,
                    samples: _parserLegacy.getPPGSamples(from: bytes))
            }
    
            //check the char ID and parse data based on it
           
            switch bluetoothCharacteristic.uuid {
                
            
                /*
                uint:12,uint:12,uint:12,uint:12,
                uint:12,uint:12,uint:12,uint:12,
                uint:12,uint:12,uint:12,uint:12"
                UInt12 x 12 time samples
                eeg order: tp10 af8 tp9 af7
                */
                
                //MARK: EEG
                //parse the incoming data through the parser, which includes FFT. Returned value is an FFTResult, which updates the MuseEEG object
            //packet order
            //0 TP10: right ear
            //1 AF08: right forehead
            //2 TP09: left ear
            //3 AF07: left forehead
            case MuseConstants.CHAR_TP10:
                 _eeg.update(withFFTResult: _fft.process(eegPacket: _makeEEGPacket(i: 0)))
            case MuseConstants.CHAR_AF8:
                 _eeg.update(withFFTResult: _fft.process(eegPacket: _makeEEGPacket(i: 1)))
            case MuseConstants.CHAR_TP9:
                 _eeg.update(withFFTResult: _fft.process(eegPacket: _makeEEGPacket(i: 2)))
            case MuseConstants.CHAR_AF7:
                 _eeg.update(withFFTResult: _fft.process(eegPacket: _makeEEGPacket(i: 3)))
                 
                 //only broadcast the MuseEEG object once per cycle, giving each sensor the chance to input its new sensor data
                 delegate?.didReceive(eegPacket: convert(museEEG: _eeg))
                
                //MARK: PPG
            case MuseConstants.CHAR_PPG2:
            
                //PPG2 is what I usually use for Muse S
                //PPG3 works on Muse 2 as well
                //PPG1, PPG2, and PPG3 don't work on Muse S
                //all PPGs now work on Muse S if preset is set to 51 on init
                
                /*
                 //https://mind-monitor.com/forums/viewtopic.php?f=19&t=1379
                 //https://developer.apple.com/documentation/accelerate/signal_extraction_from_noise
                uint:24,uint:24,uint:24
                uint:24,uint:24,uint:24
                UInt24 x 6 samples
                */
                
                //print(bytes) // <-- use to print out test PPG samples
                
                //heart events examine sensor PPG2
                if let heartEvent:MusePPGHeartEvent = _ppg.getHeartEvent(from: _makePPGPacket()) {
                    
                    //broadcast the heart event
                     delegate?.didReceive(
                        ppgHeartEvent: convert(musePPGHeartEvent: heartEvent)
                     )
                }
                
                //send ppg object once per round so application can access the buffer for visualization, etc...
                delegate?.didReceive(ppgPacket: convert(musePPG: _ppg))
                
            case MuseConstants.CHAR_ACCEL:
                
                //MARK: Accel
                /*
                 pattern = "int:16,int:16,int:16,int:16,int:16,int:16,int:16,int:16,int:16"
                 Int16 9 xyz samples (x,y,z,x,y,z,x,y,z)
                */
                
                _accelRaw = Bytes.constructInt16Array(fromUInt8Array: bytes, packetTotal: 9)
                
                delegate?.didReceive(
                    accelPacket: XvAccelPacket(
                        x: _parserLegacy.getXYZ(values: _accelRaw, start: 0),
                        y: _parserLegacy.getXYZ(values: _accelRaw, start: 1),
                        z: _parserLegacy.getXYZ(values: _accelRaw, start: 2)
                    )
                )
                
            case MuseConstants.CHAR_BATTERY:
                
                //MARK: Battery
                /*
                 pattern = "uint:16,uint:16,uint:16,uint:16"
                 UInt16 battery / 512
                 UInt16 fuel gauge * 2.2
                 UInt16 adc volt
                 UInt16 temperature
                 //the rest is padding
                */
                
                _batteryRaw = Bytes.constructUInt16Array(fromUInt8Array: bytes, packetTotal: 4)
                
                //parse the percentage and send
                delegate?.didReceive(batteryPacket:
                    XvBatteryPacket(
                        percentage: Int16(_batteryRaw[0] / MuseConstants.BATTERY_PCT_DIVIDEND)
                    )
                )

            case MuseConstants.CHAR_CONTROL:
                
                //MARK: Control Commands
                //any calls to the headband cause a reply. With most its a "rc:0" response code = 0 (success)
                //getting device info or a control status send back JSON dictionaries with several vars
                //note: this package does not use packetIndex, so pass in the raw charactersitic value
                if let commandResponse: [String: Any] = _parserLegacy.parse(controlLine: bluetoothCharacteristic.value) {
                    
                    // Drop the rc field
                    var filtered = commandResponse
                    filtered.removeValue(forKey: "rc")
                    
                    // If nothing is left (i.e. it was just ["rc": 0]), ignore it
                    guard !filtered.isEmpty else {
                        return
                    }
                    
                    // Otherwise, broadcast the response
                    print("XvMuse: commandResponse:", filtered)
                    delegate?.didReceive(commandResponse: filtered)
                }
                
            default:
                print("Unused UUID:", bluetoothCharacteristic.uuid)
                break
            }
            
        }
    }
    
    //MARK: - Athena
    //packets received from Athena and passed up to the parent app
    public func didReceiveAthena(accelPacket: XvAccelPacket) {
        delegate?.didReceive(accelPacket: accelPacket)
    }
    public func didReceiveAthena(batteryPacket: XvBatteryPacket) {
        delegate?.didReceive(batteryPacket: batteryPacket)
    }
    public func didReceiveAthenaEEGSampleBuffers(
        tp9: [Float],
        af7: [Float],
        af8: [Float],
        tp10: [Float]
    ) {
        // Convert to Double to match legacy FFT pipeline
        let tp9D  = tp9.map { Double($0) }
        let af7D  = af7.map { Double($0) }
        let af8D  = af8.map { Double($0) }
        let tp10D = tp10.map { Double($0) }
        
        // Simple safety guard: all buffers should be same size
        guard tp9D.count == af7D.count,
              tp9D.count == af8D.count,
              tp9D.count == tp10D.count,
              tp9D.count > 0 else {
            print("XvMuse: Error: Athena EEG buffers not the same size or empty")
            return
        }
        
        // One timestamp for this window, same pattern as legacy (system-relative)
        let timestamp = Date().timeIntervalSince1970 - _systemLaunchTime
        
        // If you want a rolling packet index, you can track a UInt16 counter here.
        // For now, 0 is fine if your FFTManager doesn't depend on it.
        let packetIndex: UInt16 = 0
        
        func makePacket(samples: [Double], sensor: Int) -> MuseEEGPacket {
            return MuseEEGPacket(
                packetIndex: packetIndex,
                sensor: sensor,        // 0: TP9, 1: AF7, 2: AF8, 3: TP10 (legacy convention)
                timestamp: timestamp,
                samples: samples
            )
        }
        
        // Run FFT for each channel, updating your shared MuseEEG model
        _eeg.update(withFFTResult: _fft.process(eegPacket: makePacket(samples: tp9D,  sensor: 0)))
        _eeg.update(withFFTResult: _fft.process(eegPacket: makePacket(samples: af7D,  sensor: 1)))
        _eeg.update(withFFTResult: _fft.process(eegPacket: makePacket(samples: af8D,  sensor: 2)))
        _eeg.update(withFFTResult: _fft.process(eegPacket: makePacket(samples: tp10D, sensor: 3)))
        
        // Send a single combined EEG packet out, just like in the legacy path
        delegate?.didReceive(eegPacket: convert(museEEG: _eeg))
    }
    
    
    //MARK: - Test Data
    //only engage test data objects when called directly from external program
    private let _testEEGData:[TestEEGData] = [
        TestEEGNoiseData(),
//        TestEEGLooseFitData(),
        TestEEGStressData(),
        TestEEGMeditationData(),
//        TestEEGTiredData(),
//        TestEEGFallingAlseepData(),
//        TestEEGSleepingData(),
        
    ]
    private let _testPPGData:[TestPPGData] = [
        TestPPGNoiseData(),
//        TestPPGLooseFitData(),
        TestPPGStressData(),
        TestPPGMeditationData(),
//        TestPPGTiredData(),
//        TestPPGFallingAsleepData(),
//        TestPPGSleepingData(),
        
        
    ]
    public func getTestEEG(id:Int) -> XvEEGPacket {
        
        //keep in bounds
        var dataID:Int = id-1
        if (dataID >= _testEEGData.count) {
            print("XvMuse: getTestEEG(id): Error: ID", dataID, "out of bounds of", _testEEGData.count, "- Using array max")
            dataID = _testEEGData.count-1
        }
        
        //loop through all four sensors, getting test data and processing it via FFT
        for i:Int in 0..<4 {
            let testEEGPacket:MuseEEGPacket = _testEEGData[dataID].getPacket(for: i)
            _testEEG.update(withFFTResult: _fft.process(eegPacket: testEEGPacket))
        }
        //after the four sensors are processed, return the object to use by the application
        return convert(museEEG: _testEEG)
        
    }
    
    public func getTestPPG(id:Int) -> XvPPGPacket {
       
        //keep in bounds
        var dataID:Int = id-1
        if (dataID >= _testPPGData.count) {
            print("XvMuse: getTestPPG(id): Error: ID", dataID, "out of bounds of", _testPPGData.count, "- Using array max")
            dataID = _testPPGData.count-1
        }
        
        //process middle sensor
        let testPPGPacket:MusePPGPacket = _testPPGData[dataID].getPacket()
        if let testHeartEvent:MusePPGHeartEvent = _testPPG.getHeartEvent(from: testPPGPacket) {
            
            //broadcast the heart event
            delegate?.didReceive(ppgHeartEvent: convert(musePPGHeartEvent: testHeartEvent))
        }
        
        //send to delegate if application wants to visualize the ppg buffer
        delegate?.didReceive(ppgPacket: convert(musePPG: _testPPG))
       
        //after the sensors are processed, return the object to use by the application
        return convert(musePPG: _testPPG)
    }
    
    //MARK: - BLUETOOTH CONNECTION
    public var connected:Bool = false
    
    func isAttemptingConnection() {
        onMain { self.delegate?.museIsAttemptingConnection() }
    }
    
    public func isConnecting() {
        onMain { self.delegate?.museIsConnecting() }
    }
    
    public func didConnect() {
    
        connected = true
        
        //communication protocol
        //https://sites.google.com/a/interaxon.ca/muse-developer-site/muse-communication-protocol
        
        //version handshake, set to v2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.bluetooth.versionHandshake()
        }
        
        //config commands, if desired
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in
            
            //uncomment to turn off PPG
            //setting the preset turns off the PPG
            //bluetooth.set(preset: MuseConstants.PRESET_20)
            
            //print("Version?", majorVersion, minorVersion)
            if (deviceName == .museS) {
                print("XvMuse: Using MuseS preset 51")
                bluetooth.set(preset: MuseConstants.PRESET_51)
            } else if (deviceName == .museAthena) {
                print("XvMuse: Init Athena")
                bluetooth.athenaInitializeAndStart()
            }
            
            
            //sets host platform to Mac
            //bluetooth.set(hostPlatform: MuseConstants.HOST_PLATFORM_MAC)
        }
        
        //get status
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.bluetooth.controlStatus()
        }
        
        //notify delegate
        onMain { self.delegate?.museDidConnect() }
    }
    
    public func didDisconnect() {
        connected = false
        onMain { self.delegate?.museDidDisconnect() }
    }
    
    public func didLoseConnection() {
        connected = false
        onMain { self.delegate?.museLostConnection() }
    }
    
    
    //MARK: - Thread -
    // Single lane for all DSP + parsing (keeps _fft/history thread-safe)
    private let processingQ = DispatchQueue(label: "com.primaryassembly.xvmuse.processing", qos: .userInitiated)

    // Tiny helper so every delegate call hits main safely
    @inline(__always)
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
    
    //MARK: - MOCK DATA -
    //if the muse disconnects, this pipes in test EEG data until the muse can reconnect
    fileprivate var eegTestDataLoop:Timer = Timer()
    fileprivate var ppgTestDataLoop:Timer = Timer() //PPG has its own timer interval
    fileprivate var testDataSet:Int = 0
    internal func startTestData(set:Int){
        print("MuseHelper: startTestData: Set", set)
        testDataSet = set
        eegTestDataLoop.invalidate()
        eegTestDataLoop = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(generateTestEEGData), userInfo: nil, repeats: true)
        ppgTestDataLoop.invalidate()
        ppgTestDataLoop = Timer.scheduledTimer(timeInterval: 0.10, target: self, selector: #selector(generateTestPPGData), userInfo: nil, repeats: true)
        
    }
    
    @objc func generateTestEEGData() {
        //grabs pre-recorded EEG data from muse framework
        delegate?.didReceive(eegPacket: getTestEEG(id: testDataSet))
    }
    @objc func generateTestPPGData() {
        //grabs pre-recorded PPG data from muse framework
        delegate?.didReceive(ppgPacket: getTestPPG(id: testDataSet))
    }
    
    internal func stopTestData(){
        eegTestDataLoop.invalidate()
        ppgTestDataLoop.invalidate()
    }
   
    
    //MARK: - Converters -
    
    //ordered left ear, left forehead, right forehead, right ear
    private func convert(museEEG:MuseEEG) -> XvEEGPacket {
        
        return XvEEGPacket(
            
            sensors: [
                XvEEGSensorPacket(
                    area: XvEEGScalpLocation.TP.rawValue,
                    index: 9,
                    spectrum: _eeg.TP9.linearSpectrum
                ),
                XvEEGSensorPacket(
                    area: XvEEGScalpLocation.AF.rawValue,
                    index: 7,
                    spectrum: _eeg.AF7.linearSpectrum
                ),
                XvEEGSensorPacket(
                    area: XvEEGScalpLocation.AF.rawValue,
                    index: 8,
                    spectrum: museEEG.AF8.linearSpectrum
                ),
                XvEEGSensorPacket(
                    area: XvEEGScalpLocation.TP.rawValue,
                    index: 10,
                    spectrum: museEEG.TP10.linearSpectrum
                )
            ]
        )
    }
    
    private func convert(musePPG:MusePPG) -> XvPPGPacket {
        return XvPPGPacket(waveform: musePPG.buffer)
    }
    
    private func convert(musePPGHeartEvent:MusePPGHeartEvent) -> XvPPGHeartEvent {
        return XvPPGHeartEvent(
            amplitude: musePPGHeartEvent.amplitude,
            bpm: musePPGHeartEvent.bpm,
            hrv: musePPGHeartEvent.hrv
        )
    }
}
