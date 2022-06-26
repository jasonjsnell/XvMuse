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

//another object or a view controller that can listen to this class's updates
public protocol XvMuseDelegate:AnyObject {
    
    //syntax:
    //didReceiveUpdate from sensor
    //didReceive object
    
    func didReceiveUpdate(from eeg:XvMuseEEG)
    //func didReceive(eegPacket:XvMuseEEGPacket)
    
    func didReceiveUpdate(from ppg:XvMusePPG)
    func didReceive(ppgHeartEvent:XvMusePPGHeartEvent)
    //func didReceive(ppgPacket:XvMusePPGPacket)
    
    func didReceiveUpdate(from accelerometer:XvMuseAccelerometer)
    func didReceiveUpdate(from battery:XvMuseBattery)
    
    func didReceive(commandResponse:[String:Any])
    
    //bluetooth connection updates
    func museIsConnecting()
    func museDidConnect()
    func museDidDisconnect()
    func museLostConnection()
    
}

//MARK: - STRUCTS -
//data objects that get sent to the observer when updates come in from the headband

//MARK: Packets
/* Each time the Muse headband fires off an EEG sensor update (order is: tp10 af8 tp9 af7),
the XvMuse class puts that data into XvMuseEEGPackets
and sends it here to create a streaming buffer, slice out epoch windows, and return Fast Fourier Transformed array of frequency data
       
       ch1     ch2     ch3     ch4  < EEG sensors tp10 af8 tp9 af7
                       ---     ---
0:00    p       p     | p |   | p | < XvMuseEEGPacket is one packet of a 12 sample EEG reading, index, timestamp, channel ID
0:01    p       p     | p |    ---
0:02    p       p     | p |     p
0:03    p       p     | p |     p
0:04    p       p     | p |     p
0:05    p       p     | p |     p
                       ___

                        ^ DataBuffer of streaming samples. Each channel has it's own buffer
*/

public class XvMusePacket {
    
    public var packetIndex:UInt16 = 0
    public var sensor:Int = 0 // 0 to 4: tp10 af8 tp9 af7 aux
    public var timestamp:Double = 0 // milliseconds since packet creation
    public var samples:[Double] = [] // 12 samples of EEG sensor data
    
    public init(packetIndex:UInt16, sensor:Int, timestamp:Double, samples:[Double]){
        self.packetIndex = packetIndex
        self.sensor = sensor
        self.timestamp = timestamp
        self.samples = samples
    }
}

public class XvMuseEEGPacket:XvMusePacket {}
public class XvMusePPGPacket:XvMusePacket {}

//MARK: Accel
public struct XvMuseAccelerometer {
    public var packetIndex:UInt16 = 0
    public var x:Double = 0 //head forward / back
    public var y:Double = 0 //head to shoulder
    public var z:Double = 0 //jumping up and down
    public var raw:[Int16] = []
}

//MARK: Battery
public struct XvMuseBattery {
    public var packetIndex:UInt16 = 0
    public var percentage:UInt16 = 0
    public var raw:[UInt16] = []
}


public class XvMuse:MuseBluetoothObserver {
    
    //MARK: - VARS -
    
    //queue
    fileprivate let museQueue:DispatchQueue
    
    /* Receives commands from the view controller (like keyDown), translates and sends them to the Muse, and receives data back via parse(bluetoothCharacteristic func */
    public var bluetooth:MuseBluetooth
    
    //the view controller that receives EEG, accel, PPG, etc updates
    public weak var delegate:XvMuseDelegate?
    
    public var eeg:XvMuseEEG { get { return _eeg } }
    public var ppg:XvMusePPG { get { return _ppg } }
    
    //MARK: Mock Data
    //only engage mock data objects when called directly from external program
    fileprivate let _mockEEGData:[XvMockEEGData] = [MockEEGTiredData(), MockEEGMeditationData(), MockEEGStressData(), MockEEGNoiseData()]
    public func getMockEEG(id:Int) -> XvMuseEEG {
        
        //keep in bounds
        var dataID:Int = id
        if (dataID >= _mockEEGData.count) {
            print("XvMuse: getMockEEG(id): Error: ID out of bounds. Using array max")
            dataID = _mockEEGData.count-1
        }
        
        //loop through all four sensors, getting mock data and processing it via FFT
        for i:Int in 0..<4 {
            let mockEEGPacket:XvMuseEEGPacket = _mockEEGData[dataID].getPacket(for: i)
            _mockEEG.update(with: _fft.process(eegPacket: mockEEGPacket))
        }
        //after the four sensors are processed, return the object to use by the application
        return _mockEEG
        
    }
    fileprivate let _mockPPGData:[MockPPGData] = [MockPPGTiredData(), MockPPGMeditationData(), MockPPGStressData(), MockPPGNoiseData()]
    public func getMockPPG(id:Int) -> XvMusePPG {
       
        //keep in bounds
        var dataID:Int = id
        if (dataID >= _mockPPGData.count) {
            print("XvMuse: getMockPPG(id): Error: ID out of bounds. Using array max")
            dataID = _mockPPGData.count-1
        }
        
        //process middle sensor
        let mockPPGPacket:XvMusePPGPacket = _mockPPGData[dataID].getPacket()
        if let heartEvent:XvMusePPGHeartEvent = _mockPPG.getHeartEvent(from: mockPPGPacket) {
            
            //broadcast the heart event
            delegate?.didReceive(ppgHeartEvent: heartEvent)
        }
        
        //send to delegate if application wants to visualize the ppg buffer
        delegate?.didReceiveUpdate(from: _mockPPG)
       
        //after the sensors are processed, return the object to use by the application
        return _mockPPG
    }
    
    
    //MARK: Private
    //sensor data objects
    fileprivate var _eeg:XvMuseEEG
    fileprivate var _mockEEG:XvMuseEEG
    fileprivate var _accel:XvMuseAccelerometer
    fileprivate var _ppg:XvMusePPG
    fileprivate var _mockPPG:XvMusePPG
    fileprivate var _battery:XvMuseBattery

    //helper classes
    fileprivate let _parser:Parser = Parser() //processes incoming data into useable / readable values
    fileprivate var _fft:FFT = FFT()
    
    //grabs a timestamp when the system launches, to make timestamps easier to read
    fileprivate let _systemLaunchTime:Double = Date().timeIntervalSince1970
    
    fileprivate let debug:Bool = true
    
    //MARK: - INIT -
    public init(deviceUUID:String? = nil, eegWavesAndRegionProcessing:Bool = true) {

        museQueue = DispatchQueue(label: "jasonjsnell.XvMuse.queue")
        
        
        //if a valid device ID string comes in, make a CBUUID for the bluetooth object
        var deviceCBUUID:CBUUID?
        
        if (deviceUUID != nil) {
            deviceCBUUID = CBUUID(string: deviceUUID!)
        }
        
        _eeg = XvMuseEEG(eegWavesAndRegionProcessing: eegWavesAndRegionProcessing)
        _mockEEG = XvMuseEEG(eegWavesAndRegionProcessing: eegWavesAndRegionProcessing)
        _accel = XvMuseAccelerometer()
        _ppg = XvMusePPG()
        _mockPPG = XvMusePPG()
        _battery = XvMuseBattery()
        
        bluetooth = MuseBluetooth(deviceCBUUID: deviceCBUUID)
        
        
        museQueue.async { [self] in
            bluetooth.observer = self
            bluetooth.start()
        }
    }
    
    
    //MARK: - DATA PROCESSING -
    
    public func parse(bluetoothCharacteristic: CBCharacteristic) {
        
        museQueue.async { [self] in
            
            if let _data:Data = bluetoothCharacteristic.value { //validate incoming data as not nil
                
                var bytes:[UInt8] = [UInt8](_data) //move into an array
                
                let packetIndex:UInt16 = _parser.getPacketIndex(fromBytes: bytes) //remove and store package index
                bytes.removeFirst(2) //2 bytes is 1 UInt16 package index

                //get a current timestamp, and substract the system launch time so it's a smaller, more readable number
                let timestamp:Double = Date().timeIntervalSince1970 - _systemLaunchTime
                
                // local func to make EEG packet from the above variables
                
                func _makeEEGPacket(i:Int) -> XvMuseEEGPacket {
                    
                    let packet:XvMuseEEGPacket = XvMuseEEGPacket(
                        packetIndex: packetIndex,
                        sensor: i,
                        timestamp: timestamp,
                        samples: _parser.getEEGSamples(from: bytes))

                    //delegate?.didReceive(eegPacket: packet) //send to observer in case someone wants to do their own FFT processing
                    //if (i == 2) { print(bytes, ",") }
                    
                    return packet // return assembled packet
                }
                
                // local func to make PPG packet from the above variables
                
                func _makePPGPacket() -> XvMusePPGPacket {
                    
                    let packet:XvMusePPGPacket = XvMusePPGPacket(
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
                    //parse the incoming data through the parser, which includes FFT. Returned value is an FFTResult, which updates the XvMuseEEG object
                //packet order
                //0 TP10: right ear
                //1 AF08: right forehead
                //2 TP09: left ear
                //3 AF07: left forehead
                case XvMuseConstants.CHAR_TP10:
                     _eeg.update(with: _fft.process(eegPacket: _makeEEGPacket(i: 0)))
                case XvMuseConstants.CHAR_AF8:
                     _eeg.update(with: _fft.process(eegPacket: _makeEEGPacket(i: 1)))
                case XvMuseConstants.CHAR_TP9:
                     _eeg.update(with: _fft.process(eegPacket: _makeEEGPacket(i: 2)))
                case XvMuseConstants.CHAR_AF7:
                     _eeg.update(with: _fft.process(eegPacket: _makeEEGPacket(i: 3)))
                     
                     //only broadcast the XvMuseEEG object once per cycle, giving each sensor the chance to input its new sensor data
                     delegate?.didReceiveUpdate(from: _eeg)
                    
                    //MARK: PPG
                case XvMuseConstants.CHAR_PPG2:
                    
                    /*
                     //https://mind-monitor.com/forums/viewtopic.php?f=19&t=1379
                     //https://developer.apple.com/documentation/accelerate/signal_extraction_from_noise
                    uint:24,uint:24,uint:24
                    uint:24,uint:24,uint:24
                    UInt24 x 6 samples
                    */
                    
                    //print(bytes) // <-- use to print out mock PPG samples
                    
                    //heart events examine sensor PPG2
                    if let heartEvent:XvMusePPGHeartEvent = _ppg.getHeartEvent(from: _makePPGPacket()) {
                        
                        //broadcast the heart event
                         delegate?.didReceive(ppgHeartEvent: heartEvent)
                    }
                    
                    //send ppg object once per round so application can access the buffer for visualization, etc...
                    delegate?.didReceiveUpdate(from: _ppg)
                    
                case XvMuseConstants.CHAR_ACCEL:
                    
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
                    
                    delegate?.didReceiveUpdate(from: _accel)
                    
                case XvMuseConstants.CHAR_BATTERY:
                   
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
                    _battery.percentage = _battery.raw[0] / XvMuseConstants.BATTERY_PCT_DIVIDEND
                    
                    delegate?.didReceiveUpdate(from: _battery)

                case XvMuseConstants.CHAR_CONTROL:
                    
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
    
    public func isConnecting() {
        museQueue.async { [self] in
            delegate?.museIsConnecting()
        }
    }
    
    public func didConnect() {
        
        museQueue.async { [self] in
        
            //communication protocol
            //https://sites.google.com/a/interaxon.ca/muse-developer-site/muse-communication-protocol
            
            //version handshake, set to v2
            museQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
                bluetooth.versionHandshake()
            }
            
            //set preset to 21, meaning no aux sensor is being used
            museQueue.asyncAfter(deadline: .now() + 0.9) { [self] in
                
                //setting the preset turns off the PPG
                //bluetooth.set(preset: XvMuseConstants.PRESET_20)
                bluetooth.set(hostPlatform: XvMuseConstants.HOST_PLATFORM_MAC)
            }
            
            //get status
            museQueue.asyncAfter(deadline: .now() + 1.0) { [self] in
                
                bluetooth.controlStatus()
            }
            
            //notify delegate
            delegate?.museDidConnect()
        }
    }
    
    public func didDisconnect() {
        museQueue.async { [self] in
            delegate?.museDidDisconnect()
        }
    }
    
    public func didLoseConnection() {
        museQueue.async { [self] in
            delegate?.museLostConnection()
        }
    }
}
