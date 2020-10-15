//
//  FFT.swift
//  FFT
//
//  Created by Jason Snell on 6/24/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

/*

Each time the Muse headband fires off an EEG sensor update (order is: tp10 af8 tp9 af7),
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

 // Flow: Packet --> Buffer --> Epoch --> FFT

/* A circular, updating stream of samples (each sensor has it's own sample array). It includes a corresponding timestamp array, which has fewer slots, since there is one timestamp per every 12 samples. This stream is produced by the Buffer object */

public struct DataStream {
    public var sensor:Int // same as data packet
    public var samples:[Double] = [] // streaming samples of EEG sensor data
    public var timestamps:[Double] = [] //series of recent timestamps
}

/* This is a snapshot of data from the data stream, containing values in a specific window of time. This object is released from the Epoch Manager every X milliseconds and has a bin length equal to the Buffer */

public struct Epoch {
    public var sensor:Int // same as data stream
    public var samples:[Double] = [] // X amount of EEG samples in a specific window of time
}

/* This stores the different FFT result arrays, including magnitudes (above zero, absolute values) and decibels (which the Muse SDK outputs) */

public struct FFTResult {
    public var sensor:Int // same as epoch
    public var magnitudes:[Double] //absolute, above zero values
    public var decibels:[Double] //decibels, which go above and below 0
}


public class FFT {
    
    /* Instead of doing 2D arrays of 256 samples for each sensor, I'm optmizing the FFT processing by resuing the Epoch Generator and FFT Transformer for all data. The Buffers needs one object per sensor because it is storing an ongoing stream of data from each sensor. The epoch generator is just one object, but has an array of start times, since that's the only var that needs to be sensor-specific. And the FFT transformer processes different data each func call, with no data persisting inbetween calls, so I'm using one object to process the data of all the sensors (they all take turns sending in and processing their samples, getting their returned FFT data) */
    
    fileprivate var _buffers:[Buffer] = []
    fileprivate var _epochGenerator:EpochGenerator = EpochGenerator()
    fileprivate var _ffTransformer:FFTransformer = FFTransformer(
        bins: XvMuseConstants.EEG_FFT_BINS
    )
    
    public init() {
        
        for i in 0..<XvMuseConstants.EEG_SENSOR_TOTAL {
            _buffers.append(Buffer(sensor:i))
        }
    }
    
    //An eeg data packet is sent in from the XvMuse class
    public func process(eegPacket:XvMuseEEGPacket) -> FFTResult? {
        
        // once the buffer is full (it needs a few seconds of data before it can provide a stream)...
        if let dataStream:DataStream = _buffers[eegPacket.sensor].add(packet: eegPacket) {
            
            //send the data stream to the epoch manager
            
            //once the epoch interval is complete...
            if let epoch:Epoch = _epochGenerator.getEpoch(from: dataStream) {
                
                //perform Fast Fourier Transform
                if let fftResult:FFTResult = _ffTransformer.transform(epoch: epoch) {
                    
                    //return the result
                    return fftResult
                }
            }
        }
        
        return nil
    }
}

