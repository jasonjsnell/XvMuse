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
public protocol XvMuseObserver:class {
    
    //syntax:
    //didReceiveUpdate from sensor
    //didReceive object
    
    func didReceiveUpdate(from eeg:XvMuseEEG)
    func didReceive(eegPacket:XvMuseEEGPacket)
    
    func didReceiveUpdate(from ppg:XvMusePPG)
    func didReceive(ppgHeartEvent:XvMusePPGHeartEvent)
    func didReceive(ppgBpmPacket:XvMusePPGBpmPacket)
    func didReceive(ppgPacket:XvMusePPGPacket)
    
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
    
    //MARK: Public
    /* Receives commands from the view controller (like keyDown), translates and sends them to the Muse, and receives data back via parse(bluetoothCharacteristic func */
    public var bluetooth:MuseBluetooth
    
    //the view controller that receives EEG, accel, PPG, etc updates
    public weak var observer:XvMuseObserver?
    
    public var eeg:XvMuseEEG { get { return _eeg } }
    public var ppg:XvMusePPG { get { return _ppg } }
    
    //MARK: Private
    //sensor data objects
    fileprivate var _eeg:XvMuseEEG = XvMuseEEG()
    fileprivate var _accel:XvMuseAccelerometer = XvMuseAccelerometer()
    fileprivate var _ppg:XvMusePPG = XvMusePPG()
    fileprivate var _battery:XvMuseBattery = XvMuseBattery()

    
    //helper classes
    fileprivate let _parser:Parser = Parser() //processes incoming data into useable / readable values
    fileprivate var _fft:FFT = FFT()
    
    //grabs a timestamp when the system launches, to make timestamps easier to read
    fileprivate let _systemLaunchTime:Double = Date().timeIntervalSince1970
    
    fileprivate let debug:Bool = true
    
    //MARK: - INIT -
    public init(deviceCBUUID:CBUUID? = nil) {

        bluetooth = MuseBluetooth(deviceCBUUID: deviceCBUUID)
        bluetooth.observer = self
        
    }
    
    
    //MARK: - DATA PROCESSING -
    
    public func parse(bluetoothCharacteristic: CBCharacteristic) {
        
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
                
                observer?.didReceive(eegPacket: packet) //send to observer in case someone wants to do their own FFT processing
                
                return packet // return assembled packet
            }
            
            // local func to make PPG packet from the above variables
            
            func _makePPGPacket(i:Int) -> XvMusePPGPacket {
                
                let packet:XvMusePPGPacket = XvMusePPGPacket(
                    packetIndex: packetIndex,
                    sensor: i,
                    timestamp: timestamp,
                    samples: _parser.getPPGSamples(from: bytes))
                
                observer?.didReceive(ppgPacket: packet) //send to observer in case someone wants to do their own PPG processing
                
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
            case XvMuseConstants.CHAR_TP10:
                 _eeg.update(with: _fft.process(eegPacket: _makeEEGPacket(i: 0)))
            case XvMuseConstants.CHAR_AF8:
                 _eeg.update(with: _fft.process(eegPacket: _makeEEGPacket(i: 1)))
            case XvMuseConstants.CHAR_TP9:
                 _eeg.update(with: _fft.process(eegPacket: _makeEEGPacket(i: 2)))
            case XvMuseConstants.CHAR_AF7:
                 _eeg.update(with: _fft.process(eegPacket: _makeEEGPacket(i: 3)))
                 
                 //only broadcast the XvMuseEEG object once per cycle, giving each sensor the chance to input its new sensor data
                 observer?.didReceiveUpdate(from: _eeg)
                
                //MARK: PPG
            case XvMuseConstants.CHAR_PPG1:
                
                //https://mind-monitor.com/forums/viewtopic.php?f=19&t=1379
                //https://developer.apple.com/documentation/accelerate/signal_extraction_from_noise

                /*
                uint:24,uint:24,uint:24
                uint:24,uint:24,uint:24
                UInt24 x 6 samples
                */
                
                let _:PPGResult? = _ppg.update(with: _makePPGPacket(i: 0))
                
            case XvMuseConstants.CHAR_PPG2:
                
                //if result is fired (from a heart event)
                if let result:PPGResult = _ppg.update(with: _makePPGPacket(i: 1)) {
                    
                    //broadcast the heart event
                    observer?.didReceive(ppgHeartEvent: result.heartEvent)
                    
                    //and AV heart events include bpm updates, so if that is valid, broadcast it
                    if let bpmPacket:XvMusePPGBpmPacket = result.bpmPacket {
                        observer?.didReceive(ppgBpmPacket: bpmPacket)
                    }
                    
                }
                
            case XvMuseConstants.CHAR_PPG3:
                
                let _:PPGResult? = _ppg.update(with: _makePPGPacket(i: 2))
                
                //only broadcast the XvMusePPG object once per cycle, giving each sensor the chance to input its new sensor data
                observer?.didReceiveUpdate(from: _ppg)
                
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
                
                observer?.didReceiveUpdate(from: _accel)
                
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
                
                observer?.didReceiveUpdate(from: _battery)

            case XvMuseConstants.CHAR_CONTROL:
                
                //MARK: Control Commands
                //any calls to the headband cause a reply. With most its a "rc:0" response code = 0 (success)
                //getting device info or a control status send back JSON dictionaries with several vars
                //note: this package does not use packetIndex, so pass in the raw charactersitic value
                if let commandResponse:[String:Any] =  _parser.parse(controlLine: bluetoothCharacteristic.value) {
                    
                    //if a response more than ["rc":0] comes in, broadcast it
                    observer?.didReceive(commandResponse: commandResponse)
                }
               
            default:
               break
            }
        }
    }
    
    //MARK: - BLUETOOTH CONNECTION
    
    public func isConnecting() {
        observer?.museIsConnecting()
    }
    
    public func didConnect() {
        observer?.museDidConnect()
    }
    
    public func didDisconnect() {
        observer?.museDidDisconnect()
    }
    
    public func didLoseConnection() {
        observer?.museLostConnection()
    }
}
