//
//  XvMusePPGSensor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/25/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

/*
 Muse 2
 sensor 0 - most sensitive
 sensor 1 - medium sensitive
 sensor 2 - least sensitve
 */

import XvSensors

internal class MusePPGSensor {

    private var id: Int
    private var deviceName:XvDeviceName = .unknown
    
    
    
    init(id: Int) {
        self.id = id
    }
    internal func set(deviceName:XvDeviceName) {
        self.deviceName = deviceName
        switch deviceName {
        case .museAthena:
            //2026 02 21 tests on Muse Athena - calibrated and responsive to breath
            lpAlpha = 0.02
            baselineSamples = RingBuffer(capacity: 64)
            baselineFirstSamples = RingBuffer(capacity: 64)
            baselineAveragedFirstSamples = RingBuffer(capacity: 16)
        default:
            //2026 02 21 tests on Muse 2 and S - calibrated and responsive to breath
            lpAlpha = 0.03
            baselineSamples = RingBuffer(capacity: 24)
            baselineFirstSamples = RingBuffer(capacity: 24)
            baselineAveragedFirstSamples = RingBuffer(capacity: 16)
        }
        
    }

    //MARK: - Incoming Data

    //this is where packets from the device, via bluetooth, come in for processing
    //these raw, time-based samples are what create the heartbeat pattern
    
    // Buffers (avoid O(n) removeFirst shifting)
    private var bloodFlowSamples = RingBuffer(capacity: 128)
    
    //smoothing buffers for resp
    private var baselineSamples = RingBuffer(capacity: 16)
    private var baselineFirstSamples = RingBuffer(capacity: 16)
    private var baselineAveragedFirstSamples = RingBuffer(capacity: 16)

    // low-passed baseline "flow" value
    private var lpBaseline: Double = 0.0
    private var lpInitialized = false
    
    // higher is more responsive, but more likely to pick up heart beat movements
    // lower is less resposnive, but less likely to pick up heart beat movements
    private var lpAlpha: Double = 0.005
    
    // normalizes the streams so Muse 2/S and Athena work with their different ranges
    private var bloodFlowNormalizer:StreamNormalizer = StreamNormalizer()
    private let respNormalizer:StreamNormalizer = StreamNormalizer()

    internal func getStreams(from packet: MusePPGPacket) -> MusePPGStreams? {
        
        //need to know which device is being used before processing streams
        guard deviceName != .unknown else { return nil }
        
        // append incoming samples and update baseline per sample
        for sample in packet.samples {
            
            // blood flow history
            //normalize the sample so it works with various devices
            let normalizedSample: Double = bloodFlowNormalizer.update(with: sample, smoothingOn: true)
            
            bloodFlowSamples.append(normalizedSample)

            // update low-pass baseline
            if !lpInitialized {
                lpBaseline = normalizedSample
                lpInitialized = true
            } else {
                lpBaseline += lpAlpha * (normalizedSample - lpBaseline)
            }
            
            //store it in baseline samples
            //print("")
            //print("sample", sample, normalizedSample)
            //print("lpBaseline", lpBaseline)
            baselineSamples.append(lpBaseline)
        }
        
        
        //convert baseline samples to an array
        let baselineSamplesArray = baselineSamples.toArray()
        
        //get the min and first
        if let baselineMin:Double = baselineSamplesArray.min(),
           let baselineFirst:Double = baselineSamplesArray.first {
                
            //save the scaled version of the sample
            baselineFirstSamples.append(baselineFirst - baselineMin)
            
            //get median value of baselineAverageSamples array
            let baselineFirstArray = baselineFirstSamples.toArray()
            let baselinAveragedFirstSample:Double = baselineFirstArray.reduce(0.0, +) / Double(baselineFirstArray.count)
            
            //normalize without smooothing
            let normalizedInvertedBaselineAveragedFirstSample = 1.0 - respNormalizer.update(with: baselinAveragedFirstSample, smoothingOn: true)
            //print("baselinAveragedFirstSample", baselinAveragedFirstSample, normalizedBaselineAveragedFirstSample)
     
            baselineAveragedFirstSamples.append(normalizedInvertedBaselineAveragedFirstSample)
        }
        
        let bloodFlow = bloodFlowSamples.toArray()
        let resp = baselineAveragedFirstSamples.toArray()

        //print("resp", resp[0])
        //block if the resp stream isn't populated yet
        if (resp[0] == 0.0) { return nil }
        
        return MusePPGStreams(bloodFlow: bloodFlow, resp: resp)
    }

    //muse PPG is at 256 Hz
    //https://mind-monitor.com/forums/viewtopic.php?f=19&t=1379
    //muse lsl python script uses 64 samples
    //https://github.com/alexandrebarachant/muse-lsl/blob/0afbdaafeaa6592eba6d4ff7869572e5853110a1/muselsl/constants.py

}


final class StreamNormalizer {
    // EWMA stats
    private var mean: Double = 0.0
    private var variance: Double = 0.0
    private var initialized = false
    private let alpha: Double = 0.01

    // EMA smoothing of normalized 0–1
    private var ema: Double = 0.0
    private let smoothing: Double = 0.2

    // Clamp range for z-score before mapping
    private let zClamp: ClosedRange<Double> = -2.0...2.0

    // Rolling min/max for range normalization
    private var minVal: Double = .infinity
    private var maxVal: Double = -.infinity
    private let rangeDecay: Double = 0.001

    init() {}

    // Update with a new raw sample; returns a 0…100 control
    func update(with x: Double, smoothingOn:Bool) -> Double {
        // Update rolling min/max
        if x < minVal { minVal = x }
        if x > maxVal { maxVal = x }
        if rangeDecay > 0 {
            let mid = (minVal + maxVal) * 0.5
            minVal += rangeDecay * (mid - minVal)
            maxVal += rangeDecay * (mid - maxVal)
        }
        let range = max(maxVal - minVal, 1e-9)
        let sample = (x - minVal) / range

        // Update EWMA stats
        if !initialized {
            mean = sample
            variance = 0.0
            initialized = true
        } else {
            let diff = sample - mean
            mean += alpha * diff
            variance = (1.0 - alpha) * (variance + alpha * diff * diff)
        }

        // Compute z-score
        let std = max(variance, 1e-9).squareRoot()
        let z = (sample - mean) / std

        // Clamp, map to 0…1
        let zClamped = min(max(z, zClamp.lowerBound), zClamp.upperBound)
        let normalized = (zClamped - zClamp.lowerBound) / (zClamp.upperBound - zClamp.lowerBound)
        
        if (!smoothingOn) {
            return normalized
        } else {
            // EMA smooth
            let smoothed: Double
            if ema == 0.0 {
                smoothed = normalized
            } else {
                smoothed = smoothing * normalized + (1.0 - smoothing) * ema
            }
            ema = smoothed

            // Return 0…100
            return smoothed
        }
        
    }

    func reset() {
        mean = 0.0
        variance = 0.0
        ema = 0.0
        initialized = false
        minVal = .infinity
        maxVal = -.infinity
    }
}
