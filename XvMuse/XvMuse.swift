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
    
}

//MARK: - STRUCTS -
//data objects that get sent to the observer when updates come in from the headband

//MARK: Packets
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

internal class MuseEEGPacket:MusePacket {}
internal class MusePPGPacket:MusePacket {}

//MARK: Accel
internal struct MuseAccel {
    internal var packetIndex:UInt16 = 0
    internal var x:Double = 0 //head forward / back
    internal var y:Double = 0 //head to shoulder
    internal var z:Double = 0 //jumping up and down
    internal var raw:[Int16] = []
}

//MARK: Battery
internal struct MuseBattery {
    internal var packetIndex:UInt16 = 0
    internal var percentage:Int16 = 0
    internal var raw:[UInt16] = []
}

//MARK: - MUSE -
public class XvMuse:MuseBluetoothObserver {
    
    //MARK: - vars

    /* Receives commands from the view controller (like keyDown), translates and sends them to the Muse, and receives data back via parse(bluetoothCharacteristic func */
    public var bluetooth:MuseBluetooth
    
    //the view controller that receives EEG, accel, PPG, etc updates
    public weak var delegate:XvMuseDelegate?
    
    //public var eeg:XvEEG { get { return _eeg } }
    //public var ppg:XvPPG { get { return _ppg } }
    
    //MARK: - Mock Data
    //only engage mock data objects when called directly from external program
    private let _mockEEGData:[XvMockEEGData] = [MockEEGTiredData(), MockEEGMeditationData(), MockEEGStressData(), MockEEGNoiseData()]
    public func getMockEEG(id:Int) -> XvEEGPacket {
        
        //keep in bounds
        var dataID:Int = id
        if (dataID >= _mockEEGData.count) {
            print("XvMuse: getMockEEG(id): Error: ID out of bounds. Using array max")
            dataID = _mockEEGData.count-1
        }
        
        //loop through all four sensors, getting mock data and processing it via FFT
        for i:Int in 0..<4 {
            let mockEEGPacket:MuseEEGPacket = _mockEEGData[dataID].getPacket(for: i)
            _mockEEG.update(withFFTResult: _fft.process(eegPacket: mockEEGPacket))
        }
        //after the four sensors are processed, return the object to use by the application
        return convert(museEEG: _mockEEG) 
        
    }
    private let _mockPPGData:[MockPPGData] = [MockPPGTiredData(), MockPPGMeditationData(), MockPPGStressData(), MockPPGNoiseData()]
    public func getMockPPG(id:Int) -> XvPPGPacket {
       
        //keep in bounds
        var dataID:Int = id
        if (dataID >= _mockPPGData.count) {
            print("XvMuse: getMockPPG(id): Error: ID out of bounds. Using array max")
            dataID = _mockPPGData.count-1
        }
        
        //process middle sensor
        let mockPPGPacket:MusePPGPacket = _mockPPGData[dataID].getPacket()
        if let mockHeartEvent:MusePPGHeartEvent = _mockPPG.getHeartEvent(from: mockPPGPacket) {
            
            //broadcast the heart event
            delegate?.didReceive(ppgHeartEvent: convert(musePPGHeartEvent: mockHeartEvent))
        }
        
        //send to delegate if application wants to visualize the ppg buffer
        delegate?.didReceive(ppgPacket: convert(musePPG: _mockPPG))
       
        //after the sensors are processed, return the object to use by the application
        return convert(musePPG: _mockPPG) 
    }
    
    
    //MARK: - Private
    //sensor data objects
    private var _eeg:MuseEEG
    private var _mockEEG:MuseEEG
    private var _accel:MuseAccel
    private var _ppg:MusePPG
    private var _mockPPG:MusePPG
    private var _battery:MuseBattery

    //helper classes
    private let _parser:Parser = Parser() //processes incoming data into useable / readable values
    private var _fft:FFTManager = FFTManager()
    
    //grabs a timestamp when the system launches, to make timestamps easier to read
    private let _systemLaunchTime:Double = Date().timeIntervalSince1970
    
    private var deviceUUID:String?
    
    private let debug:Bool = true
    
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
        _mockEEG = MuseEEG()
        
        _ppg = MusePPG()
        _mockPPG = MusePPG()
        
        _accel = MuseAccel()
        
        _battery = MuseBattery()
        
        bluetooth = MuseBluetooth(deviceCBUUID: deviceCBUUID)
        bluetooth.delegate = self
        bluetooth.start()
    }
    
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
    
    public func userSelectedMuse(museDevice:CBPeripheral){
        
        bluetooth.stop() //stop the search
        bluetooth.load(muse: museDevice) //load user selected muse
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.bluetooth.connect()
        }
    }
    
    public func startMuse(){
        print("XvMuse: Start streaming Muse data")
        bluetooth.startStreaming()
    }
    
    
    //MARK: - DATA PROCESSING -
    internal func parse(bluetoothCharacteristic: CBCharacteristic) {
        
        processingQ.async { [weak self] in
            guard let self = self else { return }
        
        
            if let _data:Data = bluetoothCharacteristic.value { //validate incoming data as not nil
                
                var bytes:[UInt8] = [UInt8](_data) //move into an array
                
                let packetIndex:UInt16 = _parser.getPacketIndex(fromBytes: bytes) //remove and store package index
                bytes.removeFirst(2) //2 bytes is 1 UInt16 package index

                //get a current timestamp, and substract the system launch time so it's a smaller, more readable number
                let timestamp:Double = Date().timeIntervalSince1970 - _systemLaunchTime
                
                // local func to make EEG packet from the above variables
                
                func _makeEEGPacket(i:Int) -> MuseEEGPacket {
                    
                    let packet:MuseEEGPacket = MuseEEGPacket(
                        packetIndex: packetIndex,
                        sensor: i,
                        timestamp: timestamp,
                        samples: _parser.getEEGSamples(from: bytes))

                    //if (i == 2) { print(bytes, ",") }
                    
                    return packet // return assembled packet
                }
                
                // local func to make PPG packet from the above variables
                
                func _makePPGPacket() -> MusePPGPacket {
                    
                    let packet:MusePPGPacket = MusePPGPacket(
                        packetIndex: packetIndex,
                        sensor: 1, // only use sensor 1 (not 0 or 2)
                        timestamp: timestamp,
                        samples: _parser.getPPGSamples(from: bytes))
                    
                    //delegate?.didReceive(ppgPacket: packet) //send to observer in case someone wants to do their own PPG processing
                    
                    //print(bytes, ",")
                
                    return packet // return assembled packet
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
                    
                    /*
                     //https://mind-monitor.com/forums/viewtopic.php?f=19&t=1379
                     //https://developer.apple.com/documentation/accelerate/signal_extraction_from_noise
                    uint:24,uint:24,uint:24
                    uint:24,uint:24,uint:24
                    UInt24 x 6 samples
                    */
                    
                    //print(bytes) // <-- use to print out mock PPG samples
                    
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
                    
                    _accel.packetIndex = packetIndex
                    _accel.raw = Bytes.constructInt16Array(fromUInt8Array: bytes, packetTotal: 9)
                    
                    //parse xyz values
                    _accel.x = _parser.getXYZ(values: _accel.raw, start: 0)
                    _accel.y = _parser.getXYZ(values: _accel.raw, start: 1)
                    _accel.z = _parser.getXYZ(values: _accel.raw, start: 2)
                    
                    delegate?.didReceive(accelPacket: convert(museAccel: _accel))
                    
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
                    
                    _battery.packetIndex = packetIndex
                    _battery.raw = Bytes.constructUInt16Array(fromUInt8Array: bytes, packetTotal: 4)
                    
                    //parse the percentage
                    _battery.percentage = Int16(_battery.raw[0] / MuseConstants.BATTERY_PCT_DIVIDEND)
                    
                    delegate?.didReceive(batteryPacket: convert(museBattery: _battery))

                case MuseConstants.CHAR_CONTROL:
                    
                    //MARK: Control Commands
                    //any calls to the headband cause a reply. With most its a "rc:0" response code = 0 (success)
                    //getting device info or a control status send back JSON dictionaries with several vars
                    //note: this package does not use packetIndex, so pass in the raw charactersitic value
                    if let commandResponse:[String:Any] =  _parser.parse(controlLine: bluetoothCharacteristic.value) {
                        
                        //if a response more than ["rc":0] comes in, broadcast it
                        delegate?.didReceive(commandResponse: commandResponse)
                    }
                   
                default:
                   break
                }
            }
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            
            //uncomment to turn off PPG
            //setting the preset turns off the PPG
            //bluetooth.set(preset: XvMuseConstants.PRESET_20)
            
            //sets host platform to Mac
            self.bluetooth.set(hostPlatform: MuseConstants.HOST_PLATFORM_MAC)
        }
        
        //get status
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
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
                    spectrum: museEEG.AF7.linearSpectrum
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
    
    private func convert(museAccel:MuseAccel) -> XvAccelPacket {
        return XvAccelPacket(
            x: museAccel.x,
            y: museAccel.y,
            z: museAccel.z
        )
    }
    
    private func convert(museBattery:MuseBattery) -> XvBatteryPacket {
        return XvBatteryPacket(percentage: museBattery.percentage)
    }
}
