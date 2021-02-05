//
//  XvMuseConstants.swift
//  XvMuse
//
//  Created by Jason Snell on 6/14/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation
import CoreBluetooth

public class XvMuseConstants {
    
    public static let EEG_SENSOR_TOTAL:Int = 4
    
    //MARK: DEVICE & SERVICE -
    
    public static let SERVICE_ID:CBUUID   = CBUUID(string: "0xfe8d")
    
    //MARK: CHARACTERISTICS -
    public static let CHAR_CONTROL:CBUUID = CBUUID(string:"273E0001-4C4D-454D-96BE-F03BAC821358") //write to this to send CMNDs to the Muse
    
    public static let CHAR_TP9:CBUUID     = CBUUID(string:"273E0003-4C4D-454D-96BE-F03BAC821358") //left ear
    public static let CHAR_AF7:CBUUID     = CBUUID(string:"273E0004-4C4D-454D-96BE-F03BAC821358") //left forehead
    public static let CHAR_AF8:CBUUID     = CBUUID(string:"273E0005-4C4D-454D-96BE-F03BAC821358") //right forehead
    public static let CHAR_TP10:CBUUID    = CBUUID(string:"273E0006-4C4D-454D-96BE-F03BAC821358") //right ear
    public static let CHAR_RAUX:CBUUID    = CBUUID(string:"273E0007-4C4D-454D-96BE-F03BAC821358") //plug-in aux sensor
    public static let CHAR_GYRO:CBUUID    = CBUUID(string:"273E0009-4C4D-454D-96BE-F03BAC821358") //gyroscope
    public static let CHAR_ACCEL:CBUUID   = CBUUID(string:"273E000A-4C4D-454D-96BE-F03BAC821358") //accelometer
    public static let CHAR_BATTERY:CBUUID = CBUUID(string:"273E000B-4C4D-454D-96BE-F03BAC821358") //battery (telemetry)
    public static let CHAR_PPG1:CBUUID    = CBUUID(string:"273E000F-4C4D-454D-96BE-F03BAC821358") //ppg1
    public static let CHAR_PPG2:CBUUID    = CBUUID(string:"273E0010-4C4D-454D-96BE-F03BAC821358") //ppg2
    public static let CHAR_PPG3:CBUUID    = CBUUID(string:"273E0011-4C4D-454D-96BE-F03BAC821358") //ppg3
    
    //MARK: COMMANDS -
    //https://www.eso.org/~ndelmott/ascii.html
    //first hex is header
    //0x02 = 2 hexes will follow header
    //0x03 = 3 hexes will follow header
    //0x04 = 4 hexes will follow header
    
    //0x0a = end of hex array command
    
    //0x6b = lowercase k
    //0x68 = lowercase h
    //0x73 = lowercase s
    //0x64 = lowercase d
    //0x76 = lowercase v for version
    
    //MARK: start stop
    public static let CMND_RESUME:[UInt8] = [0x02, 0x64, 0x0a] //d = resume
    public static let CMND_HALT:[UInt8]   = [0x02, 0x68, 0x0a] //h = halt
    
    //MARK: keep alive
    public static let CMND_KEEP:[UInt8]   = [0x02, 0x6b, 0x0a] //k = keep alive
    
    //MARK: get status
    //0x73 = lowercase s
    //0x3F = ?
    public static let CMND_STATUS:[UInt8] = [0x02, 0x73, 0x0a] //s = status info
    
    //https://github.com/alexandrebarachant/muse-lsl/blob/71a45b7e062f81ffa23b96e86823a2507b8198fa/muselsl/muse.py
    //Muse LSL uses 0x31 for protocol version
    //0x30 = 0 lowest protocol version possible. Perhaps a beta version by Muse.
    //0x31 = 1 this may be protocol 2 if use array numbering (0 = 1, 1 = 2)
    //0x32 = 2 using 0x32 results in the same value on my Muse headband as 0x31. It doesn't seem to hurt the system to try to set it to this higher value
    
    //0x76 = v = protocol version
    //                                                   "v"   "2"
    //sets protocol version and returns device info
    public static let CMND_VERSION_HANDSHAKE:[UInt8] = [0x03, 0x76, 0x32, 0x0a]
    
    //MARK: set host platform
    //https://sites.google.com/a/interaxon.ca/muse-developer-site/muse-communication-protocol/serial-commands
    //0x72 = lowercase r
    //0x30 = 0
    //0x31 = 1 = iOS
    //0x32 = 2 = Android
    //0x33 = 3 = Windows
    //0x34 = 4 = Mac
    //0x35 = 5 = Linus
    //Mac command = [0x03, 0x72, 0x34, 0x0a]
    
    public static let CMND_HOST_PLATFORM_PRE:[UInt8] = [0x03, 0x72]
    public static let CMND_HOST_PLATFORM_POST:UInt8 = 0x0a
    public static let HOST_PLATFORM_IOS:UInt8 = 1
    public static let HOST_PLATFORM_ANDROID:UInt8 = 2
    public static let HOST_PLATFORM_WINDOWS:UInt8 = 3
    public static let HOST_PLATFORM_MAC:UInt8 = 4
    public static let HOST_PLATFORM_LINUX:UInt8 = 5
    public static let HOST_PLATFORM_IOS_HEX:UInt8 = 0x31
    public static let HOST_PLATFORM_ANDROID_HEX:UInt8 = 0x32
    public static let HOST_PLATFORM_WINDOWS_HEX:UInt8 = 0x33
    public static let HOST_PLATFORM_MAC_HEX:UInt8 = 0x34
    public static let HOST_PLATFORM_LINUX_HEX:UInt8 = 0x35
    
    //MARK: reset muse
    public static let CMND_RESET:[UInt8]  = [0x03, 0x2a, 0x31, 0x0a] //hard reset
    
    //MARK: set preset (default is 21)
    //https://gitmemory.com/conorato
    //Some commands are, from muse-js:
    //'p20': set to aux-enabled preset
    //'p21': set to aux-disabled
    //0x70 = lowercase p
    //format "p20"
    public static let CMND_PRESET_PRE:[UInt8] = [0x04, 0x70]
    public static let CMND_PRESET_POST:UInt8 = 0x0a
    
    //                                     2      0
    public static let P20_HEX:[UInt8] = [0x32, 0x30] //preset 20
    public static let P21_HEX:[UInt8] = [0x32, 0x31] //preset 21 (default)
    public static let P22_HEX:[UInt8] = [0x32, 0x32] //preset 22
    public static let P23_HEX:[UInt8] = [0x32, 0x33] //preset 23
    
    public static let PRESET_20:UInt8 = 20
    public static let PRESET_21:UInt8 = 21
    public static let PRESET_22:UInt8 = 22
    public static let PRESET_23:UInt8 = 23
    
    
    public static let BATTERY_PCT_DIVIDEND:UInt16 = 512
    public static let ACCEL_SCALE_FACTOR:Double = 0.0000610
    public static let GYRO_SCALE_FACTOR:Double = 0.0074768
    
    
    //MARK: EEG
    //Muse bands: https://web.archive.org/web/20181105231756/http://developer.choosemuse.com/tools/available-data#Absolute_Band_Powers
    
    public static let FREQUENCY_BAND_DELTA:[Double] = [1.5,  4.0]
    public static let FREQUENCY_BAND_THETA:[Double] = [4.0,  8.0]
    public static let FREQUENCY_BAND_ALPHA:[Double] = [7.5,  13.0]
    public static let FREQUENCY_BAND_BETA :[Double] = [13.0, 30.0]
    public static let FREQUENCY_BAND_GAMMA:[Double] = [30.0, 44.0]
    
    /*
    //order of sensors as the data comes in from muse
    public static let TP9:Int  = 2 //left ear
    public static let TP10:Int = 0 //right ear
    public static let AF7:Int  = 3 //left forehead
    public static let AF8:Int  = 1 //right forehead
    
    //same list as locations on the head
    public static let EEG_SENSOR_EAR_L:Int      = 2 //left ear
    public static let EEG_SENSOR_EAR_R:Int      = 0 //right ear
    public static let EEG_SENSOR_FOREHEAD_L:Int = 3 //left forehead
    public static let EEG_SENSOR_FOREHEAD_R:Int = 1 //right forehead
    */
    
    //MARK: FFT
    //sampling rate Hz listed here:
    //https://sites.google.com/a/interaxon.ca/muse-developer-site/museio/presets
    public static let SAMPLING_RATE:Double = 220.0
    public static let EEG_FFT_BINS:Int = 256
    public static let EPOCH_REFRESH_TIME:Double = 0.1 //in seconds, so 0.1 seconds = 100 milliseconds
    
    //MARK: PPG
    public static let PPG_RESTING:Int = 0
    public static let PPG_S1_EVENT:Int = 1
    public static let PPG_S2_EVENT:Int = 2
    
    
    
    
    
}
