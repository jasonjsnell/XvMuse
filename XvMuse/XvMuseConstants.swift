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
    
    public static let DEVICE_ID:CBUUID    = CBUUID(string: "8CDFEA1B-F9D5-4684-B9F4-CBC094CE1A0E")
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
    public static let CMND_RESUME:[UInt8] = [0x02, 0x64, 0x0a] //resume
    public static let CMND_STOP:[UInt8]   = [0x02, 0x68, 0x0a] //stop
    public static let CMND_KEEP:[UInt8]   = [0x02, 0x6b, 0x0a] //keep alive
    public static let CMND_STATUS:[UInt8] = [0x02, 0x73, 0x0a] //control status info
    public static let CMND_DEVICE:[UInt8] = [0x03, 0x76, 0x31, 0x0a] //device info
    public static let CMND_RESET:[UInt8]  = [0x03, 0x2a, 0x31, 0x0a] //hard reset
    
    public static let CMND_P20:[UInt8]    = [0x04, 0x70, 0x32, 0x30, 0x0a] //preset 20
    public static let CMND_P21:[UInt8]    = [0x04, 0x70, 0x32, 0x31, 0x0a] //preset 21 (default)
    public static let CMND_P22:[UInt8]    = [0x04, 0x70, 0x32, 0x32, 0x0a] //preset 22
    public static let CMND_P23:[UInt8]    = [0x04, 0x70, 0x32, 0x33, 0x0a] //preset 23
    
    public static let BATTERY_PCT_DIVIDEND:UInt16 = 512
    public static let ACCEL_SCALE_FACTOR:Float = 0.0000610
    public static let GYRO_SCALE_FACTOR:Float = 0.0074768
    
    
    //MARK: EEG
    //Muse bands: https://web.archive.org/web/20181105231756/http://developer.choosemuse.com/tools/available-data#Absolute_Band_Powers
    public static let FREQUENCY_BAND_DELTA:[Double] = [1,  3]
    public static let FREQUENCY_BAND_THETA:[Double] = [4,  7]
    public static let FREQUENCY_BAND_ALPHA:[Double] = [8,  12]
    public static let FREQUENCY_BAND_BETA:[Double]  = [13, 29]
    public static let FREQUENCY_BAND_GAMMA:[Double] = [30, 44]
    
    //MARK: FFT
    public static let SAMPLING_RATE:Double = 256
    public static let FFT_BINS:Int = 256
    public static let EPOCH_REFRESH_TIME:Double = 0.1 //in seconds, so 0.1 seconds = 100 milliseconds
    
    
    
    
}
