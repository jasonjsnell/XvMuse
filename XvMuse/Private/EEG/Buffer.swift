//
//  Buffer.swift
//  XvFFT
//
//  Created by Jason Snell on 6/26/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

/*
 
 Each time the Muse headband sends out readings for a sensor
 this buffer receives a XvMuseEEGPacket with those values.
 This object unpacks the XvMuseEEGPacket
 strips out the 12 samples
 and adds the samples into a continuously updating array (ex: 256 max length)
 and updates a parallel array of timestamps, which is 1/12 the length of the sample arrays (since a timestamp only occurs once every 12 samples)
 
 
 packet = [s, s, s, s, s, s, s, s, s, s, s, s], timestamp
 
 Data is repackaged as:
 
 position      samples       timestamp
 
 ---------------------------  < data from XvMuseEEGPacket added
                                
     1           s       t    < timestamp occurs once every 12 samples
     2           s
     3           s
     4           s
     5           s
     6           s
     7           s
     8           s
     9           s
     10          s
     11          s
     12          s
 ---------------------------  < data from next XvMuseEEGPacket added
     
     13          s       t    < next timestamp
     ...        ...
     256         s
 
                 ^
        the samples array fills up to 256 samples (same size as FFT bin number)
        then drops the oldest samples
        and keeps filling in the new ones
 
 */

import Foundation

class Buffer {
    
    fileprivate var _dataStream:DataStream // object which holds the samples and timestamps arrays
    fileprivate var _samplesMax:Int //max size of the samples array
    fileprivate var _timestampsMax:Int //max size of timestampls array
    
    init(sensor:Int) {
        
        //set the max for the samples and timestamps arrays
        self._samplesMax = XvMuseConstants.EEG_FFT_BINS
        
        //number of timestamps is the length of the sample buffer (ex: 256)
        //divided by 12 samples per incoming packet (12)
        //and rounded down (floor())
        _timestampsMax = Int(floor( Double(_samplesMax / 12) ))
        
        //put sensor ID into the data stream (only needs to be set once during initialization)
        _dataStream = DataStream(sensor: sensor)
        
    }
    
    //fileprivate var _buffer:DataBuffer = DataBuffer()
    public func add(packet:XvMuseEEGPacket) -> DataStream? {
        
        //MARK: Samples
        //copy the packet's samples into the sample stream
        _dataStream.samples += packet.samples
        
        //if this pushes the stream's sample array over the max
        if (_dataStream.samples.count > _samplesMax) {
            
            //remove the excess from the beginning of the array
            _dataStream.samples.removeFirst(_dataStream.samples.count-_samplesMax)
        }
        
        //MARK: Timestamps
        //add the time stamp of the first sensor in the packet to the data stream's timestamp array
        _dataStream.timestamps.append(packet.timestamp)
        
        //if the number of timestamps exceeds the max
        if (_dataStream.timestamps.count > _timestampsMax) {
            
            //remove the excess from the beginning of the array
            _dataStream.timestamps.removeFirst(_dataStream.timestamps.count-_timestampsMax)
        }
        
        //MARK: Delivery
        //if the stream is filled with _samplesMax packets (ex: 256 samples), then make it available
        if (_dataStream.samples.count == _samplesMax) {
            
            return _dataStream
        } else {
            
            print("EEG: Building buffer", _dataStream.samples.count, "/", _samplesMax)
            return nil //otherwise if it is still building, return nothing
        }
    }
}

