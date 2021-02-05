//
//  Parser.swift
//  XvMuse
//
//  Created by Jason Snell on 6/16/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

class Parser {
    
    fileprivate let debug:Bool = true
    

    //MARK: - PACKET INDEX
    // many of the characteristics include a counter that moves up with each received packet
    internal func getPacketIndex(fromBytes:[UInt8]) -> UInt16 {
        let twoByteArr:[UInt8] = [fromBytes[0], fromBytes[1]]
        return Bytes.getUInt16(fromBytes: twoByteArr)
    }
    
    //MARK: - EEG -
    
    internal func getEEGSamples(from bytes:[UInt8]) -> [Double] {
        
        //convert UInt8 array into a UInt12 array
        let UInt12Samples:[UInt16] = Bytes.constructUInt12Array(fromUInt8Array: bytes)
        
        //process these samples into the correct range
        return UInt12Samples.map { 0.48828125 * Double(Int($0) - 2048) } //0x800 = 2048
    }
    
    //MARK: - PPG -
    
    internal func getPPGSamples(from bytes:[UInt8]) -> [Double] {
        
        //get 24 bit samples and map them into an array of Doubles
        let UInt24Samples:[UInt32] = Bytes.constructUInt24Array(fromUInt8Array: bytes, packetTotal: 6)
        return UInt24Samples.map { Double($0) }
    }
    
    //MARK: - ACCEL -
    
    //gets the raw XYZ data from muse
    internal func getXYZ(values:[Int16], start:Int) -> Double {
        
        //add up every third value
        //convert to Double, otherwise total exceeds Int16 max
        let sum:Double =
            Double(values[start]) +
            Double(values[start+3]) +
            Double(values[start+6])
       
        //divide by 3 to get average and multiple by scale
        return (sum / 3) * XvMuseConstants.ACCEL_SCALE_FACTOR
    }
    
    //MARK: - CONTROL MESSAGES -
    
    //var to concat incoming messages to
    fileprivate var controlMsg:String = ""
    
    internal func parse(controlLine:Data?) -> [String:Any]? {
        
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
                    
                    //send the string to the JSON func
                    if let json:[String:Any] = JSON.getJSON(fromStr: controlMsg) {
                        
                        //print("CONTROL: json", json)
                        
                        //re-initliaze the message string for the next time a command comes in
                        controlMsg = ""
                        
                        //if the control message was a request for data, the dictionary count will be more than 1 (a length of 1 just means a response code came back, like ["rc": 0]
                        if (json.count > 1) {
                        
                            return json
                            
                        } else {
                            
                            //print from here, but don't return to main class
                            if (debug) { print("PARSER: JSON:", json) }
                            return nil
                        }
                        
                    } else {
                        
                        controlMsg = ""
                        return nil
                    }
                }
            }
            
        } else {
            print("PARSER: Error: Incoming control line is nil")
        }
        
        return nil
    }
}
