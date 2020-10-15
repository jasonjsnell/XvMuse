//
//  EpochGenerator.swift
//  XvFFT
//
//  Created by Jason Snell on 6/26/20.
//  Copyright © 2020 Jason Snell. All rights reserved.

/*
 
 An Epoch represents the EEG data that has been collected over a specific period of time. Collecting data in this way is necessary for performing frequency-based analyses. Epochs contain a an array of samples collected from a specific slice of time from the Buffer
 */

import Foundation

class EpochGenerator {
    
    //use defaults
    // this is the time interval at which epochs are released, in milliseconds
    //0.1 = every 100 milliseconds
    //1.0 = every second
    fileprivate var interval:Double
    
    //number of samples in the epoch
    //best if power of 2 (2, 4, 8, 16, 32... 256, etc)
    //and matches the FFT bin number
    fileprivate var duration:Int
    
    //an array of start times for each sensor
    //note: rather than making multiple epoch generators, like there are multiple Buffers, the only thing that is unique to each sensor's data is this start time data, so this one var can manage all the sensor's data when creating an epoch
    fileprivate var _startTimes:[Double] = []
    
    init(){
        
        self.interval = XvMuseConstants.EPOCH_REFRESH_TIME
        self.duration = XvMuseConstants.EEG_FFT_BINS
        
        //make a unique slot for each sensors start time
        for _ in 0..<XvMuseConstants.EEG_SENSOR_TOTAL{
            _startTimes.append(0.0)
        }
    }
    
    
    public func getEpoch(from dataStream:DataStream) -> Epoch? {
        
        //get the current sensor
        let sensor:Int = dataStream.sensor
        
        //get first (oldest) timestamp in the data stream's timestamp array
        if let startTime:Double = dataStream.timestamps.first {
            
            //if the interval time has passed...
            if (startTime-interval >= _startTimes[sensor]){
                
                //reset curr start time
                _startTimes[sensor] = startTime
               
                //return epoch for the FFT to process
                return Epoch(sensor: sensor, samples: dataStream.samples)
            
            } else {
                //if epoch is still being built, return nil
                //print("Epoch: Incoming timestamp:", startTime)
                return nil
            }
            
        } else {
            print("EpochGenerator: Error: Incoming timestamp array is blank.")
            return nil
        }
        
    }
    
    
    
}

