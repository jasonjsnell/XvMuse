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
    
    /* THE GATE (13 Oct 2026). Two ways to decide when a sensor's next epoch is due.

     .time(seconds): the original rule. An epoch is released when the newest packet timestamp
     is at least `seconds` past the timestamp of the last epoch. Default, so other apps see
     no change.

     .samples(n): an epoch is released every n samples. Counting samples instead of reading
     the clock makes the FFT cadence a function of the data alone: the same recording gives the
     same epochs run after run, and a machine that is behind does not release more epochs per
     packet, which the time gate did when the timestamps were taken in the processing block. */
    internal enum EpochGate {
        case time(Double)
        case samples(Int)
    }

    internal var gate: EpochGate = .time(XvMuseConstants.EPOCH_REFRESH_TIME)

    /* The lean lever (13 Oct 2026). 1 is normal. 2 or 4 stretches the gate (need = n x
     multiplier, interval x multiplier) so a slow machine does half or a quarter of the FFT
     work while every packet still lands in the window. Set by XvMuse from the load governor. */
    internal var gateMultiplier: Int = 1
    
    //an array of start times for each sensor
    //note: rather than making multiple epoch generators, like there are multiple Buffers, the only thing that is unique to each sensor's data is this start time data, so this one var can manage all the sensor's data when creating an epoch
    private var _startTimes:[Double] = []
    
    //sample-gate state, one slot per sensor (13 Oct 2026)
    private var samplesSinceEpoch:[Int] = []
    private var hasReleased:[Bool] = []

    init(){
        
        //make a unique slot for each sensors start time
        for _ in 0..<XvMuseConstants.EEG_SENSOR_TOTAL{
            _startTimes.append(0.0)
            samplesSinceEpoch.append(0)
            hasReleased.append(false)
        }
    }
    
    /* newSampleCount: how many samples the packet that triggered this call added to the stream.
     allowed: false while a burst or a backlog is being worked off. The samples are still
     counted, so the gate's view of the stream stays true, but nothing is released. In sample
     mode the count is clamped at the need so that, once allowed again, exactly one epoch fires
     on the next packet instead of a burst of them. */
    public func getEpoch(from dataStream:DataStream, newSampleCount:Int, allowed:Bool) -> Epoch? {
        
        //get the current sensor
        let sensor:Int = dataStream.sensor
        
        // Safety check: make sure the sensor index is valid for the _startTimes array
        guard sensor >= 0 && sensor < _startTimes.count else {
            print("EpochGenerator: Invalid sensor index:", sensor)
            return nil
        }
        
        let multiplier = max(1, gateMultiplier)

        switch gate {

        case .time(let interval):

            // Get the most recent timestamp from the incoming EEG data stream.
            // .last is used because new data packets append their timestamp here,
            // so this reflects the current "end" of the rolling buffer (i.e., most recent EEG arrival time).
            guard let latestTime:Double = dataStream.timestamps.last else {
                print("EpochGenerator: Error: Incoming timestamp array is blank.")
                return nil
            }

            //not releasing: leave the reference point alone, as if this packet had not been seen
            guard allowed else { return nil }

            // Check if enough time has passed since the last epoch was released.
            // Each sensor has its own _startTimes[sensor].
            // If the latest timestamp is greater than or equal to the previous start time + interval,
            // then we know it's time to generate another epoch.
            // (interval x 1.0 is exact, so the default multiplier leaves the comparison as it was)
            if latestTime >= _startTimes[sensor] + interval * Double(multiplier) {

                // Update the reference point for this sensor so we don't emit epochs too quickly.
                _startTimes[sensor] = latestTime
                return makeEpoch(sensor: sensor, from: dataStream)
            }
            return nil

        case .samples(let n):

            samplesSinceEpoch[sensor] += newSampleCount
            let need = max(1, n) * multiplier

            guard allowed else {
                samplesSinceEpoch[sensor] = min(samplesSinceEpoch[sensor], need)
                return nil
            }

            //the first full window releases at once, as the time gate did from a start time of 0
            if !hasReleased[sensor] || samplesSinceEpoch[sensor] >= need {
                hasReleased[sensor] = true
                samplesSinceEpoch[sensor] = 0
                return makeEpoch(sensor: sensor, from: dataStream)
            }
            return nil
        }
    }
        
    // Return a new Epoch object representing the *current snapshot* of EEG data in the
    // rolling buffer. One allocation: the ring is copied straight into the epoch's own
    // storage, oldest sample first, so the Epoch is unaffected by later appends.
    private func makeEpoch(sensor:Int, from dataStream:DataStream) -> Epoch {
        let count = dataStream.samples.count
        let samples = [Double](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            dataStream.samples.copyChronological(into: buffer)
            initializedCount = count
        }
        return Epoch(sensor: sensor, samples: samples)
    }
}
