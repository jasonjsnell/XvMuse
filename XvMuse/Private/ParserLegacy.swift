//
//  Parser.swift
//  XvMuse
//
//  Created by Jason Snell on 6/16/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

class ParserLegacy {
    
    private let debug:Bool = true
    

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
        return (sum / 3) * MuseConstants.ACCEL_SCALE_FACTOR
    }
    
    //MARK: - CONTROL MESSAGES -
    //var to concat incoming messages to
    private var controlMsg:String = ""
    
    internal func parse(controlLine:Data?) -> [String:Any]? {
        
        //convert to data
        if let _controlLine:Data = controlLine {
            
            //grab first byte, which is length
            let lengthOfString:Int = Int(_controlLine[0])
            
            //parse through length of string, skipping first byte (which is lenght)
            for i in 1...lengthOfString {
                
                //grab bytes in a loop
                let byte:UInt8 = _controlLine[i]
                let charFromByte:Character = Character(UnicodeScalar(byte))
                controlMsg += String(charFromByte)
                
                //end char is bracket
                if (charFromByte == "}") {
                    
                    // We've reached the end of a control message
                    //print("controlMsg", controlMsg)
                    
                    let message = controlMsg
                    var json: [String: Any] = [:]
                    
                    let end = message.endIndex
                    var searchIndex = message.startIndex
                    
                    // Scan for every colon in the message
                    while let colonIndex = message[searchIndex...].firstIndex(of: ":") {
                        
                            // find the key (variable name) before the colon
                            // Find the closing quote of the key (just before the colon)
                            guard let keyEndQuote = message[..<colonIndex].lastIndex(of: "\"") else {
                                searchIndex = message.index(after: colonIndex)
                                continue
                            }
                            // Find the opening quote of the key
                            guard let keyStartQuote = message[..<keyEndQuote].lastIndex(of: "\"") else {
                                searchIndex = message.index(after: colonIndex)
                                continue
                            }
                            
                            let rawKey = String(message[message.index(after: keyStartQuote)..<keyEndQuote])
                            
                            // find value (variable value) after colon
                            var valueIndex = message.index(after: colonIndex)
                            
                            // Skip whitespace
                            while valueIndex < end && message[valueIndex].isWhitespace {
                                valueIndex = message.index(after: valueIndex)
                            }
                            if valueIndex >= end {
                                break
                            }
                            
                            var rawValue: String
                            
                            if message[valueIndex] == "\"" {
                                // Quoted string value: "...."
                                let valueStart = message.index(after: valueIndex)
                                guard let valueEndQuote = message[valueStart...].firstIndex(of: "\"") else {
                                    // malformed string, skip this colon
                                    searchIndex = message.index(after: colonIndex)
                                    continue
                                }
                                rawValue = String(message[valueStart..<valueEndQuote])
                                // Advance searchIndex for next colon
                                searchIndex = message.index(after: valueEndQuote)
                            } else {
                                // Non-quoted value (number, etc.) up to ',' or '}'
                                let valueStart = valueIndex
                                var valueEnd = valueIndex
                                while valueEnd < end && message[valueEnd] != "," && message[valueEnd] != "}" {
                                    valueEnd = message.index(after: valueEnd)
                                }
                                rawValue = String(message[valueStart..<valueEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                                searchIndex = valueEnd
                            }
                            
                            // ---- CONVERT VALUE TYPE ----
                            let value: Any
                            if let intVal = Int(rawValue) {
                                value = intVal
                            } else if let doubleVal = Double(rawValue) {
                                value = doubleVal
                            } else {
                                value = rawValue
                            }
                            
                            // ---- STORE  ----
                            if json[rawKey] == nil {
                                json[rawKey] = value
                            }
                    }
                    
                    // Reset for next message
                    controlMsg = ""
                    
                    //print("JSON", json)
                    
                    if !json.isEmpty {
                        return json
                    } else {
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
