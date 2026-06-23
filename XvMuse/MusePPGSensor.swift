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
        respSignalProcessor.reset()
        bloodFlowSamples = RingBuffer<Double>(capacity: 128)
        _detectionSampleIndex = 0
        legacyChannelNormalizers = []
        legacyChannelLatestValues = []
        baselineAveragedFirstSamples = RingBuffer<Double>(capacity: 16)
        ampDCBaseline = 0.0
        ampEnvelope = 0.0
        ampEnvelopeRef = 1e-6
        ampTrackingInitialized = false
        rawAmplitude = 0.0
        switch deviceName {
        case .museAthena:
            ampDCAlpha = 1.0 / (30.0 * 64.0)
            ampEnvDecayAlpha = 1.0 / (3.0 * 64.0)
        default:
            ampDCAlpha = 1.0 / (30.0 * 256.0)
            ampEnvDecayAlpha = 1.0 / (3.0 * 256.0)
        }

    }

    //MARK: - Incoming Data

    //this is where packets from the device, via bluetooth, come in for processing
    //these raw, time-based samples are what create the heartbeat pattern
    
    // blood flow buffer
    private var bloodFlowSamples = RingBuffer<Double>(capacity: 128)
    
    // resp output history
    private var baselineAveragedFirstSamples = RingBuffer<Double>(capacity: 16)

    private var _respPrintCounter: Int = 0
    private var _lastTraceTimestamp: Double = 0 // HRV timing trace: prev packet arrival time

    // Regular sample-clock for beat timing. Muse PPG hardware streams at 64 Hz; the BLE
    // packet-arrival timestamp (Date()) is jittery and shared by all 6 samples, which
    // quantizes + jitters beat intervals. Counting samples on the detection channel and
    // deriving time = index / 64 gives a regular grid immune to BLE delivery jitter.
    private let ppgSampleRate: Double = 64.0
    private var _detectionSampleIndex: Int = 0
    private var _rawStartupCount: Int = 0 // startup diagnostic: raw vs normalized detection signal

    // Raw amplitude tracking — works on pre-normalization optical values so z-score
    // normalization doesn't erase true pump strength information.
    private var ampDCBaseline: Double = 0.0       // 30s time-constant DC removal
    private var ampEnvelope: Double = 0.0         // peak-hold, 3s decay
    private var ampEnvelopeRef: Double = 1e-6     // slow-decaying historical peak for normalization
    private var ampTrackingInitialized: Bool = false
    private var ampDCAlpha: Double = 0.0          // set per device in set(deviceName:)
    private var ampEnvDecayAlpha: Double = 0.0
    internal var rawAmplitude: Double = 0.0       // 0–1, high = pumping hard
    
    // normalizes the streams so Muse 2/S and Athena work with their different ranges
    private var bloodFlowNormalizer:StreamNormalizer = StreamNormalizer()
    private let respSignalProcessor = RespiratorySignalProcessor(sampleRate: 64.0)
    private var legacyChannelNormalizers: [StreamNormalizer] = []
    private var legacyChannelLatestValues: [Double?] = []

    internal func getStreams(
        from packet: MusePPGPacket,
        allowsRespMetrics: Bool = true
    ) -> MusePPGStreams? {
        
        //need to know which device is being used before processing streams
        guard deviceName != .unknown else { return nil }

        // === Dropped-packet watch ===
        // The 64 Hz sample-clock assumes no gaps; a lost packet makes it under-count vs real
        // time and would compress one beat interval. Flag likely gaps (normal cadence ~0.094s
        // for 6 samples @ 64 Hz) so we can spot HRV artifacts from packet loss.
        if deviceName == .museAthena || packet.sensor == legacyRespChannelIndex {
            let dt = _lastTraceTimestamp == 0 ? 0 : packet.timestamp - _lastTraceTimestamp
            _lastTraceTimestamp = packet.timestamp
            if dt > 0.15 {
                print(String(format: "TRACE GAP | sensor:%d dt:%.5f (~%d packets missed)",
                             packet.sensor, dt, Int((dt / 0.09375).rounded()) - 1))
            }
        }

        // Beat detection runs only on the detection channel (Athena single, or Muse 2 PPG2),
        // so each of its samples gets a regular 64 Hz sample-clock time for clean beat timing.
        let isDetectionChannel = (deviceName == .museAthena) || (packet.sensor == legacyRespChannelIndex)
        var newSamples: [(t: Double, x: Double)] = []
        var latestRespSample: RespiratorySignalSample?
        var respDiagnostic: MuseRespDiagnostic?

        // append incoming samples and update baseline per sample
        for sample in packet.samples {
            let sampleSet = normalizedSamples(for: sample, fromSensor: packet.sensor)
            let normalizedSample = sampleSet.bloodFlow

            bloodFlowSamples.append(normalizedSample)

            // Track raw amplitude on Athena (single channel) or Muse 2 IR channel (PPG2).
            // Must use pre-normalization values — z-score normalization erases amplitude info.
            if isDetectionChannel {
                updateRawAmplitude(sample)

                if let detectionSample = sampleSet.detectionSource {
                    let t = Double(_detectionSampleIndex) / ppgSampleRate
                    _detectionSampleIndex += 1
                    newSamples.append((t: t, x: detectionSample))

                    // Startup diagnostic: is the RAW pulse flat (contact/hardware) or is the
                    // normalizer flattening a real pulse? Prints first ~25s, every 4th sample.
                    if _rawStartupCount < 1600 {
                        if _rawStartupCount % 4 == 0 {
                            // print(String(format: "RAW | i:%d  raw:%.1f  norm:%.4f", _rawStartupCount, sample, detectionSample))
                        }
                        _rawStartupCount += 1
                    }
                }
            }

            if allowsRespMetrics, let respSourceSample = sampleSet.respSource {
                latestRespSample = respSignalProcessor.update(rawSample: respSourceSample)
            }
        }
        
        if allowsRespMetrics, let respSample = latestRespSample {
            baselineAveragedFirstSamples.append(respSample.output)
            respDiagnostic = MuseRespDiagnostic(
                raw: respSample.raw,
                lp1: respSample.highPassed,
                lp2: respSample.bandPassed,
                bandPassed: respSample.bandPassed,
                depth: respSample.depth,
                normalized: respSample.depth,
                output: respSample.output
            )

            _respPrintCounter += 1
            if _respPrintCounter % 32 == 0 {
                // BREATH TRACE in XvMuse prints this at a fixed cadence with accel movement.
            }
        }

        let bloodFlow = bloodFlowSamples.toArray()
        let resp = allowsRespMetrics ? baselineAveragedFirstSamples.toArray() : []

        guard allowsRespMetrics else {
            return MusePPGStreams(bloodFlow: bloodFlow, resp: resp, newSamples: newSamples)
        }

        //block until the resp stream has at least one populated value
        guard let firstResp = resp.first, firstResp != 0.0 else { return nil }

        return MusePPGStreams(
            bloodFlow: bloodFlow,
            resp: resp,
            respDiagnostic: respDiagnostic,
            newSamples: newSamples
        )
    }

    private func normalizedSamples(for sample: Double, fromSensor sensor: Int) -> (bloodFlow: Double, respSource: Double?, detectionSource: Double?) {
        guard deviceName != .museAthena else {
            let value = bloodFlowNormalizer.update(with: sample, smoothingOn: true)
            return (value, sample, value)
        }

        ensureLegacyChannelStorage()
        let channelIndex = min(max(sensor, 0), legacyPPGChannelCount - 1)
        let channelValue = legacyChannelNormalizers[channelIndex].update(with: sample, smoothingOn: true)
        legacyChannelLatestValues[channelIndex] = channelValue

        let activeValues = legacyChannelLatestValues.compactMap { $0 }
        let combined = activeValues.isEmpty
            ? channelValue
            : activeValues.reduce(0.0, +) / Double(activeValues.count)
        let respSource = channelIndex == legacyRespChannelIndex ? sample : nil
        // Detection runs on the combined multi-channel average (more robust at startup than a
        // single channel warming up alone), gated to the detection channel so it fires once/packet.
        let detectionSource = channelIndex == legacyRespChannelIndex ? combined : nil
        return (combined, respSource, detectionSource)
    }

    private func updateRawAmplitude(_ sample: Double) {
        if !ampTrackingInitialized {
            ampDCBaseline = sample
            ampTrackingInitialized = true
            return
        }
        // Remove DC: slow EMA tracks the resting optical level (~30s time constant)
        ampDCBaseline += ampDCAlpha * (sample - ampDCBaseline)
        let ac = abs(sample - ampDCBaseline)
        // Envelope follower: instant attack, slow decay (~3s time constant)
        if ac > ampEnvelope {
            ampEnvelope = ac
        } else {
            ampEnvelope -= ampEnvDecayAlpha * ampEnvelope
        }
        // Slow-decaying historical peak for normalization: stretches to each new maximum,
        // decays very slowly so sustained hard pumping stays elevated
        if ampEnvelope > ampEnvelopeRef {
            ampEnvelopeRef = ampEnvelope
        } else {
            ampEnvelopeRef -= (ampDCAlpha * 0.3) * ampEnvelopeRef
        }
        rawAmplitude = ampEnvelopeRef > 1e-9 ? min(1.0, ampEnvelope / ampEnvelopeRef) : 0.0
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

private struct RespiratorySignalSample {
    var raw: Double
    var highPassed: Double
    var bandPassed: Double
    var depth: Double
    var output: Double
}

private final class RespiratorySignalProcessor {

    private let highPassAlpha: Double
    private let lowPassAlpha: Double
    private let outputAlpha: Double
    private let envelopeFallAlpha: Double
    private let referenceRiseAlpha: Double
    private let referenceFallAlpha: Double
    private let warmupSamples: Int
    private let outputPolarity: Double = 1.0
    private let outputGain: Double = 0.47        // final swing around center: 0.5 ± this (rails ~0.03/0.97)
    private let phaseSoftness: Double = 1.2      // lower = more excursion per breath (tanh + clamp keep it safe)

    private var initialized = false
    private var dcBaseline: Double = 0.0
    private var lowPassedBand: Double = 0.0
    private var lowPassedBand2: Double = 0.0
    private var envelope: Double = 0.0
    private var referenceEnvelope: Double = 1e-6
    private var warmupMaxEnvelope: Double = 1e-6
    private var sampleCount: Int = 0
    private var output: Double = 0.5

    // Slow-AGC depth preservation: an absolute floor on the normalizing scale, plus warmup
    // accumulators to calibrate a representative "typical breath" size over the first ~30s.
    private var ampFloor: Double = 0.0
    private var warmupEnvSum: Double = 0.0
    private var warmupEnvCount: Int = 0

    init(sampleRate: Double) {
        self.highPassAlpha = Self.onePoleAlpha(cutoffHz: 0.05, sampleRate: sampleRate)
        // Applied as two cascaded stages (see update) → −12 dB/oct at 0.4 Hz, the breath/heart gap.
        self.lowPassAlpha = Self.onePoleAlpha(cutoffHz: 0.4, sampleRate: sampleRate)
        self.outputAlpha = Self.onePoleAlpha(cutoffHz: 1.0, sampleRate: sampleRate)
        self.envelopeFallAlpha = Self.onePoleAlpha(cutoffHz: 0.18, sampleRate: sampleRate)
        // Reference adapts over tens of seconds (rise ~40s / fall ~80s) so a single deep or
        // shallow breath cannot move the scale — that is what preserves breath depth.
        self.referenceRiseAlpha = Self.onePoleAlpha(cutoffHz: 0.004, sampleRate: sampleRate)
        self.referenceFallAlpha = Self.onePoleAlpha(cutoffHz: 0.002, sampleRate: sampleRate)
        // Warm up over ~30s so the typical-breath scale is built from several full breaths.
        self.warmupSamples = Int(sampleRate * 30.0)
    }

    func reset() {
        initialized = false
        dcBaseline = 0.0
        lowPassedBand = 0.0
        lowPassedBand2 = 0.0
        envelope = 0.0
        referenceEnvelope = 1e-6
        warmupMaxEnvelope = 1e-6
        sampleCount = 0
        output = 0.5
        ampFloor = 0.0
        warmupEnvSum = 0.0
        warmupEnvCount = 0
    }

    func update(rawSample: Double) -> RespiratorySignalSample {
        guard initialized else {
            initialized = true
            dcBaseline = rawSample
            output = 0.5
            let sample = RespiratorySignalSample(
                raw: rawSample,
                highPassed: 0.0,
                bandPassed: 0.0,
                depth: 0.0,
                output: output
            )
            return sample
        }

        dcBaseline += highPassAlpha * (rawSample - dcBaseline)
        let highPassed = rawSample - dcBaseline
        // Two cascaded 1-pole low-passes at 0.4 Hz (−12 dB/oct). A single pole was too shallow
        // and let the cardiac pulse (~0.75–1.5 Hz) bleed through and ripple the output; this
        // sits in the gap between max breathing (~0.4 Hz) and min heart rate (~0.75 Hz / 45 bpm),
        // passing the breath while pushing the heartbeat down ~4× further. bp = lowPassedBand2.
        lowPassedBand += lowPassAlpha * (highPassed - lowPassedBand)
        lowPassedBand2 += lowPassAlpha * (lowPassedBand - lowPassedBand2)

        let bandMagnitude = abs(lowPassedBand2)
        if bandMagnitude > envelope {
            envelope = bandMagnitude
        } else {
            envelope += envelopeFallAlpha * (bandMagnitude - envelope)
        }

        sampleCount += 1
        warmupMaxEnvelope = max(warmupMaxEnvelope, envelope)
        if sampleCount < warmupSamples {
            // Accumulate a representative breath size from the first ~30s of breathing.
            warmupEnvSum += envelope
            warmupEnvCount += 1
            referenceEnvelope = max(warmupMaxEnvelope, 1e-6)
        } else if sampleCount == warmupSamples {
            let warmupMean = warmupEnvCount > 0 ? warmupEnvSum / Double(warmupEnvCount) : warmupMaxEnvelope
            referenceEnvelope = max(warmupMean, 1e-6)
            // Floor stops the slow AGC from zooming into shallow breathing (which would
            // re-inflate small breaths to full scale). 40% of the typical warmup breath.
            ampFloor = 0.4 * referenceEnvelope
        } else {
            let refAlpha = envelope > referenceEnvelope ? referenceRiseAlpha : referenceFallAlpha
            referenceEnvelope += refAlpha * (envelope - referenceEnvelope)
            referenceEnvelope = max(referenceEnvelope, 1e-6)
        }

        let scale = max(max(referenceEnvelope, ampFloor), 1e-6)
        // Relative breath depth (typical ≈ 1, deep > 1, shallow < 1); diagnostic only.
        let depth = min(2.5, envelope / scale)
        // Soft-saturating 0–1 map of the band-passed breath (bp). tanh preserves depth — a
        // deeper breath gives a larger excursion — and rolls off instead of hard-clipping.
        let phase = tanh(lowPassedBand2 / (phaseSoftness * scale))
        let target = max(0.0, min(1.0, 0.5 + outputPolarity * outputGain * phase))
        output += outputAlpha * (target - output)

        let sample = RespiratorySignalSample(
            raw: rawSample,
            highPassed: highPassed,
            bandPassed: lowPassedBand2,
            depth: depth,
            output: output
        )
        return sample
    }

    private static func onePoleAlpha(cutoffHz: Double, sampleRate: Double) -> Double {
        return 1.0 - exp(-2.0 * Double.pi * cutoffHz / sampleRate)
    }
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
