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
    func didReceiveUpdate(from eeg:XvMuseEEG)
    func didReceiveUpdate(from eegPacket:XvMuseEEGPacket)
    func didReceiveUpdate(from accelerometer:XvMuseAccelerometer)
    func didReceiveUpdate(from battery:XvMuseBattery)
    
}

//MARK: - STRUCTS -
//data objects that get sent to the observer when updates come in from the headband

//MARK: Packet
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

public struct XvMuseEEGPacket {
    
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

public struct XvMusePPG {
    
}

public struct XvMuseAccelerometer {
    public var packetIndex:UInt16 = 0
    public var x:Double = 0 //head forward / back
    public var y:Double = 0 //head to shoulder
    public var z:Double = 0 //jumping up and down
    public var raw:[Int16] = []
}

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
    
    public var printControlMessages:Bool {
        get { return _parser.printControlMessages }
        set { _parser.printControlMessages = newValue}
    }
    
    //MARK: Private
    //sensor data objects
    fileprivate var _eeg:XvMuseEEG = XvMuseEEG()
    fileprivate var _accel:XvMuseAccelerometer = XvMuseAccelerometer()
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
            
            //local func to make EEG packet from the above variables
            
            func _makeEEGPacket(i:Int) -> XvMuseEEGPacket {
                
                let packet:XvMuseEEGPacket = XvMuseEEGPacket(
                    packetIndex: packetIndex,
                    sensor: i,
                    timestamp: timestamp,
                    samples: _parser.getEEGSamples(fromBytes: bytes))
                
                observer?.didReceiveUpdate(from: packet) //send to observer in case someone wants to do their own FFT processing
                
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
                
                //https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6651860/
                //https://github.com/marnixnaber/rPPG/blob/master/rPPG.m
                //https://developer.apple.com/documentation/XvAccelerometererate/finding_the_component_frequencies_in_a_composite_sine_wave
                /*
                uint:24,uint:24,uint:24
                uint:24,uint:24,uint:24
                UInt24 x 6 samples
                */
                break
                
                
            case XvMuseConstants.CHAR_PPG2:
                
                print("ppg2")
               
                let UInt24Samples:[UInt32] = Bytes.constructUInt24Array(fromUInt8Array: bytes, packetTotal: 6)
                print(UInt24Samples)
                
            case XvMuseConstants.CHAR_PPG3:
                
                print("ppg3")
               
                let UInt24Samples:[UInt32] = Bytes.constructUInt24Array(fromUInt8Array: bytes, packetTotal: 6)
                print(UInt24Samples)
                
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
                _parser.parse(controlLine: bluetoothCharacteristic.value)
               
            default:
               break
            }
        }
    }
}
