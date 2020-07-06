//
//  Parser.swift
//  XvMuse
//
//  Created by Jason Snell on 6/16/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation
import XvUtils

class Parser {
    

    //MARK: - PACKET INDEX
    // many of the characteristics include a counter that moves up with each received packet
    internal func getPacketIndex(fromBytes:[UInt8]) -> UInt16 {
        let twoByteArr:[UInt8] = [fromBytes[0], fromBytes[1]]
        let hex:String = Hex.getHex(fromBytes: twoByteArr)
        if let index:UInt16 = Hex.getUInt16(fromHex: hex) {
            return index
        } else {
            print("EEG:Parser: Unable to get packet index from bytes")
            return 0
        }
    }
    
    //MARK: - EEG -
    
    internal func getEEGSamples(fromBytes:[UInt8]) -> [Float] {
        
        //convert UInt8 array into a UInt12 array
        let UInt12Samples:[UInt16] = Bytes.constructUInt12Array(fromUInt8Array: fromBytes)
        
        //process these samples into the correct range
        return UInt12Samples.map { 0.48828125 * Float(Int($0) - 2040) }
    }
    
    //MARK: - ACCEL -
    
    //gets the raw XYZ data from muse
    internal func getXYZ(values:[Int16], start:Int) -> Float {
        
        //add up every third value
        //convert to float, otherwise total exceeds Int16 max
        let sum:Float =
            Float(values[start]) +
            Float(values[start+3]) +
            Float(values[start+6])
       
        //divide by 3 to get average and multiple by scale
        return (sum / 3) * XvMuseConstants.ACCEL_SCALE_FACTOR
    }
    
    //MARK: - CONTROL MESSAGES -
    
    //var to concat incoming messages to
    fileprivate var controlMsg:String = ""
    
    internal func parse(controlLine:Data?) {
        
        if let _controlLine:Data = controlLine {
            
            //first byte in control line is the number of useable characters
            //if all bytes are used, random text from other lines is at the end of each line
            let lengthOfString:Int = Int(_controlLine[0])
            
            //loop through the bytes, skipping the first (which is the length of the string)
            for i in 1...lengthOfString {
                
                //grab the byte
                let byte:UInt8 = _controlLine[i]
                
                //convert it to a character
                let charFromByte:Character = Character(UnicodeScalar(byte))
                
                //append it to the msg array
                controlMsg += String(charFromByte)
                
                //if the character is the close bracket...
                if (charFromByte == "}") {
                    
                    print("CONTROL: Message received")
                    
                    //send the string to the JSON func
                    if let json:[String:Any] = JSON.getJSON(fromStr: controlMsg) {
                        
                        //print result
                        print("CONTROL: JSON", json)
                    }
                    
                    //re-initliaze the message string for the next time a command comes in
                    controlMsg = ""
                    
                    //stop executing
                    return
                }
            }

            //keep adding the array of characters to the global message string
            //controlMsg += String(charArr)
            //print("msg", controlMsg)
            
        } else {
            print("PARSER: Error: Incoming control line is nil")
        }
    }
}
