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
    private var interval:Double
    
    //an array of start times for each sensor
    //note: rather than making multiple epoch generators, like there are multiple Buffers, the only thing that is unique to each sensor's data is this start time data, so this one var can manage all the sensor's data when creating an epoch
    private var _startTimes:[Double] = []
    
    init(){
        
        self.interval = MuseConstants.EPOCH_REFRESH_TIME
        
        //make a unique slot for each sensors start time
        for _ in 0..<MuseConstants.EEG_SENSOR_TOTAL{
            _startTimes.append(0.0)
        }
    }
    
    
    public func getEpoch(from dataStream:DataStream) -> Epoch? {
        
        //get the current sensor
        let sensor:Int = dataStream.sensor
        
        // Safety check: make sure the sensor index is valid for the _startTimes array
        guard sensor >= 0 && sensor < _startTimes.count else {
            print("EpochGenerator: Invalid sensor index:", sensor)
            return nil
        }
        
        // Get the most recent timestamp from the incoming EEG data stream.
        // .last is used because new data packets append their timestamp here,
        // so this reflects the current "end" of the rolling buffer (i.e., most recent EEG arrival time).
        guard let latestTime:Double = dataStream.timestamps.last else {
            print("EpochGenerator: Error: Incoming timestamp array is blank.")
            return nil
        }
        
        // Check if enough time has passed since the last epoch was released.
        // Each sensor has its own _startTimes[sensor].
        // If the latest timestamp is greater than or equal to the previous start time + interval,
        // then we know it's time to generate another epoch.
        if latestTime >= _startTimes[sensor] + interval {
            
            // Update the reference point for this sensor so we don't emit epochs too quickly.
            _startTimes[sensor] = latestTime
            
            // Return a new Epoch object representing the *current snapshot*
            // of EEG data in the rolling buffer.
            // Defensive 'Array(...)' copy ensures the Epoch has its own sample data
            // and won’t be affected if the Buffer keeps appending/removing samples later.
            
            return Epoch(sensor: sensor, samples: Array(dataStream.samples))
            
        } //else {
            //print("EpochGenerator: Waiting for next epoch window")
        //}
        
        return nil
    }
}
