//
//  XvMusePPG.swift
//  XvMuse
//
//  Created by Jason Snell on 7/25/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation
import XvSensors

//created when a heartbeat is detected
internal struct MusePPGHeartEvent {
    
    init(bpm:Double = 0.0, pulseStrength:Double = 0.0, sdnn:Double = 0.0) {
        self.bpm = bpm
        self.pulseStrength = pulseStrength
        self.sdnn = sdnn
    }
    var bpm:Double
    var pulseStrength:Double
    var sdnn:Double
}

//continuous data stream of bloodflow and respiratory data
internal struct MusePPGStreams {
    internal var bloodFlow: [Double]
    internal var resp: [Double]

    init(bloodFlow: [Double], resp: [Double]) {
        self.bloodFlow = bloodFlow
        self.resp = resp
    }
}

//packet with both heart beats and stream data combined
internal struct MusePPGResult {
    var heartEvent:MusePPGHeartEvent?
    var streams:MusePPGStreams?
    init(heartEvent: MusePPGHeartEvent? = nil, streams: MusePPGStreams? = nil) {
        self.heartEvent = heartEvent
        self.streams = streams
    }
}

internal class MusePPG {
    
    init() {}
    
    internal func set(deviceName:XvDeviceName) {
        sensor.set(deviceName: deviceName)
    }
    
    internal var sensor: MusePPGSensor = MusePPGSensor(id: 0)
    private let _ppgAnalyzer: PPGAnalyzer = PPGAnalyzer()
    
    // Peak detection state
    private var lastSample: Double = 0.0
    private var lastTimestamp: Double = 0.0
    
    private var lastBeatTime: Double = 0.0
    private let minBeatInterval: Double = 0.38 // seconds (~158 bpm max)
    private var lastAcceptedBeatInterval: Double = 0.0
    
    private var candidatePeakValue: Double = 0.0
    private var candidatePeakTime: Double = 0.0
    private var wasRising: Bool = false
    
    private var candidateTroughValue: Double = 0.0
    private var candidateTroughTime: Double = 0.0
    private var lastTroughValue: Double = 0.0
    private var lastTroughTime: Double = 0.0
    
    // dynamic threshold
    private var rollingMean: Double = 0.0
    private var rollingVar: Double = 0.0
    private var rollingCount: Int = 0
    private let alpha: Double = 0.01 // EWMA factor

    // extra smoothing for beat detection to reduce jaggedness / double hits
    private var detectionSample: Double = 0.0
    private var detectionInitialized = false
    // Lower alpha = more smoothing before peak detection.
    private let detectionAlpha: Double = 0.09
    
    internal func update(withPPGPacket: MusePPGPacket, allowsHeartMetrics: Bool = true) -> MusePPGResult? {
        
        //are the streams valid? if not, no streams or heart events are returned
        guard let streams = sensor.getStreams(from: withPPGPacket) else {
            return nil
        }
        
        // current sample (normalized blood-flow sample)
        guard let rawX = streams.bloodFlow.last else { return nil }
        let t = withPPGPacket.timestamp

        let x: Double
        if detectionInitialized {
            detectionSample += detectionAlpha * (rawX - detectionSample)
            x = detectionSample
        } else {
            detectionSample = rawX
            detectionInitialized = true
            x = rawX
        }
        
        if !allowsHeartMetrics {
            wasRising = false
            lastSample = x
            lastTimestamp = t
            candidatePeakValue = x
            candidatePeakTime = t
            candidateTroughValue = x
            candidateTroughTime = t
            return MusePPGResult(heartEvent: nil, streams: streams)
        }
        
        // update rolling stats for threshold
        updateRollingStats(x)
        let noiseStd = sqrt(max(rollingVar, 1e-9))
        let dynamicThreshold = rollingMean + 0.5 * noiseStd  // tune this factor
        
        // derivative sign
        let rising = (x > lastSample)
        
        // update candidate peak when rising
        if rising {
            if !wasRising {
                
                // start of a rising phase
                candidatePeakValue = x
                candidatePeakTime = t
                
                // start of a rising phase: we just came from a trough
                // lock in the last trough
                lastTroughValue = candidateTroughValue
                lastTroughTime = candidateTroughTime
                
            } else if x > candidatePeakValue {
                // still rising, new higher candidate
                candidatePeakValue = x
                candidatePeakTime = t
            }
        }
        
        // update trough candidate when falling ---
        if !rising {
            if wasRising {
                // start of a falling phase: we just came from a peak
                candidateTroughValue = x
                candidateTroughTime = t
            } else if x < candidateTroughValue {
                candidateTroughValue = x
                candidateTroughTime = t
            }
        }
        
        var heartEvent: MusePPGHeartEvent? = nil
        
        // if we were rising and now falling -> local max candidate
        if wasRising && !rising {
            let timeSinceLastBeat = t - lastBeatTime
            let adaptiveMinimumInterval: Double
            if lastAcceptedBeatInterval > 0 {
                adaptiveMinimumInterval = max(minBeatInterval, min(lastAcceptedBeatInterval * 0.6, 0.75))
            } else {
                adaptiveMinimumInterval = minBeatInterval
            }

            let peakProminence = candidatePeakValue - lastTroughValue
            let minProminence = max(0.015, noiseStd * 0.75)

            if timeSinceLastBeat >= adaptiveMinimumInterval &&
               candidatePeakValue > dynamicThreshold &&
               peakProminence >= minProminence {
                
                lastAcceptedBeatInterval = timeSinceLastBeat
                lastBeatTime = candidatePeakTime
                
                let ppgAnalysis = _ppgAnalyzer.update(
                    at: candidatePeakTime,
                    peak: candidatePeakValue,
                    trough: lastTroughValue
                )
                
                heartEvent = MusePPGHeartEvent(
                    bpm: ppgAnalysis.bpm,
                    pulseStrength: ppgAnalysis.pulseAmp,
                    sdnn: ppgAnalysis.sdnnMs
                )
            }
        }
        
        wasRising = rising
        lastSample = x
        lastTimestamp = t
        
        return MusePPGResult(heartEvent: heartEvent, streams: streams)
    }
    
    //sub
    
    private func updateRollingStats(_ x: Double) {
        // exponential moving mean/variance
        if rollingCount == 0 {
            rollingMean = x
            rollingVar = 0.0
            rollingCount = 1
        } else {
            let diff = x - rollingMean
            rollingMean += alpha * diff
            rollingVar = (1.0 - alpha) * (rollingVar + alpha * diff * diff)
        }
    }
}
