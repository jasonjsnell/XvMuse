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
    private let legacyPPGChannelCount = 3
    private let legacyRespChannelIndex = 1 // PPG2
    
    
    
    init(id: Int) {
        self.id = id
    }
    internal func set(deviceName:XvDeviceName) {
        self.deviceName = deviceName
        bloodFlowNormalizer.reset()
        respNormalizer.reset()
        legacyRespNormalizer.reset()
        bloodFlowSamples = RingBuffer<Double>(capacity: 128)
        lpBaseline = 0.0
        lpBaseline2 = 0.0
        lpInitialized = false
        legacyRespBaseline = 0.0
        legacyRespBaseline2 = 0.0
        legacyRespInitialized = false
        respOutputEMA = 0.0
        respOutputInitialized = false
        legacyChannelNormalizers = []
        legacyChannelLatestValues = []
        baselineAveragedFirstSamples = RingBuffer<Double>(capacity: 16)
        switch deviceName {
        case .museAthena:
            lpAlpha = 0.02
        default:
            // 0.015 gives ~0.61 Hz cutoff at 256 Hz — LP lag ~0.51s total across two stages
            lpAlpha = 0.015 //0.015
        }
        
    }

    //MARK: - Incoming Data

    //this is where packets from the device, via bluetooth, come in for processing
    //these raw, time-based samples are what create the heartbeat pattern
    
    // blood flow buffer
    private var bloodFlowSamples = RingBuffer<Double>(capacity: 128)
    
    // resp output history
    private var baselineAveragedFirstSamples = RingBuffer<Double>(capacity: 16)

    // low-passed baseline "flow" value — two cascaded passes to better reject heartbeat
    private var lpBaseline: Double = 0.0
    private var lpBaseline2: Double = 0.0
    private var lpInitialized = false
    private var legacyRespBaseline: Double = 0.0
    private var legacyRespBaseline2: Double = 0.0
    private var legacyRespInitialized = false
    private var respOutputEMA: Double = 0.0
    private var respOutputInitialized = false
    
    // higher is more responsive, but more likely to pick up heart beat movements
    // lower is less resposnive, but less likely to pick up heart beat movements
    private var lpAlpha: Double = 0.005
    private var _respPrintCounter: Int = 0
    private let respOutputAlpha: Double = 0.12
    
    // normalizes the streams so Muse 2/S and Athena work with their different ranges
    private var bloodFlowNormalizer:StreamNormalizer = StreamNormalizer()
    private let respNormalizer:StreamNormalizer = StreamNormalizer()
    private let legacyRespNormalizer: StreamNormalizer = StreamNormalizer()
    private var legacyChannelNormalizers: [StreamNormalizer] = []
    private var legacyChannelLatestValues: [Double?] = []

    internal func getStreams(from packet: MusePPGPacket) -> MusePPGStreams? {
        
        //need to know which device is being used before processing streams
        guard deviceName != .unknown else { return nil }
        
        // append incoming samples and update baseline per sample
        for sample in packet.samples {
            let sampleSet = normalizedSamples(for: sample, fromSensor: packet.sensor)
            let normalizedSample = sampleSet.bloodFlow
            
            bloodFlowSamples.append(normalizedSample)

            if let respSourceSample = sampleSet.respSource {
                appendRespSourceSample(respSourceSample)
            }
        }
        
        
        if deviceName == .museAthena, lpInitialized {
            let normResp = respNormalizer.update(with: lpBaseline2, smoothingOn: true)
            let smoothResp = smoothRespOutput(normResp)
            baselineAveragedFirstSamples.append(smoothResp)

            _respPrintCounter += 1
            if _respPrintCounter % 32 == 0 {
                print(String(format: "RESP Athena | lp1:%.5f | lp2:%.5f | norm:%.5f | out:%.5f",
                      lpBaseline, lpBaseline2, normResp, smoothResp))
            }

        } else if legacyRespInitialized {
            let normResp = respNormalizer.update(with: legacyRespBaseline2, smoothingOn: true)
            let smoothResp = smoothRespOutput(normResp)
            baselineAveragedFirstSamples.append(smoothResp)

            _respPrintCounter += 1
            if _respPrintCounter % 64 == 0 {
                print(String(format: "RESP Muse2 | lp1:%.5f | lp2:%.5f | norm:%.5f | out:%.5f",
                      legacyRespBaseline, legacyRespBaseline2, normResp, smoothResp))
            }
        }
        
        let bloodFlow = bloodFlowSamples.toArray()
        let resp = baselineAveragedFirstSamples.toArray()

        //block until the resp stream has at least one populated value
        guard let firstResp = resp.first, firstResp != 0.0 else { return nil }
        
        return MusePPGStreams(bloodFlow: bloodFlow, resp: resp)
    }

    private func normalizedSamples(for sample: Double, fromSensor sensor: Int) -> (bloodFlow: Double, respSource: Double?) {
        guard deviceName != .museAthena else {
            let value = bloodFlowNormalizer.update(with: sample, smoothingOn: true)
            return (value, value)
        }

        ensureLegacyChannelStorage()
        let channelIndex = min(max(sensor, 0), legacyPPGChannelCount - 1)
        let channelValue = legacyChannelNormalizers[channelIndex].update(with: sample, smoothingOn: true)
        legacyChannelLatestValues[channelIndex] = channelValue

        let activeValues = legacyChannelLatestValues.compactMap { $0 }
        let combined = activeValues.isEmpty
            ? channelValue
            : activeValues.reduce(0.0, +) / Double(activeValues.count)
        let respSource = channelIndex == legacyRespChannelIndex
            ? legacyRespNormalizer.update(with: sample, smoothingOn: true)
            : nil
        return (combined, respSource)
    }

    private func appendRespSourceSample(_ sample: Double) {
        if deviceName == .museAthena {
            if !lpInitialized {
                lpBaseline = sample
                lpBaseline2 = sample
                lpInitialized = true
            } else {
                lpBaseline += lpAlpha * (sample - lpBaseline)
                lpBaseline2 += lpAlpha * (lpBaseline - lpBaseline2)
            }
        } else {
            if !legacyRespInitialized {
                legacyRespBaseline = sample
                legacyRespBaseline2 = sample
                legacyRespInitialized = true
            } else {
                legacyRespBaseline += lpAlpha * (sample - legacyRespBaseline)
                legacyRespBaseline2 += lpAlpha * (legacyRespBaseline - legacyRespBaseline2)
            }
        }
    }

    private func smoothRespOutput(_ sample: Double) -> Double {
        if !respOutputInitialized {
            respOutputEMA = sample
            respOutputInitialized = true
        } else {
            respOutputEMA += respOutputAlpha * (sample - respOutputEMA)
        }
        return respOutputEMA
    }

    private func ensureLegacyChannelStorage() {
        if legacyChannelNormalizers.count != legacyPPGChannelCount {
            legacyChannelNormalizers = (0..<legacyPPGChannelCount).map { _ in StreamNormalizer() }
        }
        if legacyChannelLatestValues.count != legacyPPGChannelCount {
            legacyChannelLatestValues = Array(repeating: nil, count: legacyPPGChannelCount)
        }
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
