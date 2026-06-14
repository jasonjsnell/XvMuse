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
    // The detection channel's new samples this packet, each carrying a regular 64 Hz
    // sample-clock time (NOT the jittery BLE packet-arrival time). Empty for non-detection
    // channels. Beat detection runs per-sample over these so beat timing is on a clean grid.
    internal var newSamples: [(t: Double, x: Double)]

    init(bloodFlow: [Double], resp: [Double], newSamples: [(t: Double, x: Double)] = []) {
        self.bloodFlow = bloodFlow
        self.resp = resp
        self.newSamples = newSamples
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
    // Refractory floor, gated on signal health. A real pulse keeps the detection signal's
    // variance healthy at any rate (normalization preserves the swing), so when std is healthy
    // we allow a fast floor for genuine high heart rates (kids/exercise, up to ~214 bpm). When
    // the signal collapses to flat noise (post-motion dropout), the prominence/threshold gates
    // can't tell a dicrotic/noise bump from a beat — there a high floor (~136 bpm) blocks the
    // double-counts that fire on the notch of one real beat.
    private let refractoryFloorHealthy: Double = 0.28 // ~214 bpm
    private let refractoryFloorFlat: Double = 0.44    // ~136 bpm
    private let flatSignalStd: Double = 0.03          // below this, signal is dropout, not a pulse
    private var lastAcceptedBeatInterval: Double = 0.0
    private var prevAllowedHeartMetrics: Bool = true
    
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

    // Detection now runs per-sample on a regular 64 Hz grid (was once per BLE packet on the
    // jittery Date() clock). EWMA factors are set from physical time constants so behavior is
    // defined by seconds, not sample rate:  alpha = 1 - exp(-(1/64) / tau)
    private let ppgSampleInterval: Double = 1.0 / 64.0
    private let alpha: Double = 0.025          // rolling-stats baseline, tau ~0.62s
    private let detectionAlpha: Double = 0.044 // beat smoothing, tau ~0.35s

    // extra smoothing for beat detection to reduce jaggedness / double hits
    private var detectionSample: Double = 0.0
    private var detectionInitialized = false

    private var secondLastSample: Double = 0.0 // for parabolic peak-time interpolation

    private var _detPrintCounter: Int = 0
    
    internal func update(withPPGPacket: MusePPGPacket, allowsHeartMetrics: Bool = true) -> MusePPGResult? {

        //are the streams valid? if not, no streams or heart events are returned
        guard let streams = sensor.getStreams(from: withPPGPacket) else {
            return nil
        }

        if !allowsHeartMetrics {
            // reset detection state so a stale rising edge doesn't fire a beat on resume
            wasRising = false
            if let last = streams.newSamples.last {
                lastSample = last.x
                secondLastSample = last.x
                lastTimestamp = last.t
                candidatePeakValue = last.x
                candidatePeakTime = last.t
                candidateTroughValue = last.x
                candidateTroughTime = last.t
            }
            // On the clean→blocked transition, emit a single -1 sentinel so the UI renders
            // a dash instead of stale heart values. Silent while it stays blocked.
            let blockedEvent: MusePPGHeartEvent? = prevAllowedHeartMetrics
                ? MusePPGHeartEvent(bpm: -1, pulseStrength: -1, sdnn: -1)
                : nil
            prevAllowedHeartMetrics = false
            return MusePPGResult(heartEvent: blockedEvent, streams: streams)
        }

        // Transitioning from noisy to clean: clear only the adaptive-minimum seed so it doesn't
        // block a higher post-workout rate. Do NOT wipe the HRV/BPM buffers — a brief blink
        // shouldn't throw away a minute of history. The one cross-noise gap interval is rejected
        // by the analyzer's 0.4–1.8s bound; sustained rate changes are handled by its regime
        // unstick. (Wiping here forced a cold-start rebuild that seeded SDNN with junk.)
        if !prevAllowedHeartMetrics {
            lastAcceptedBeatInterval = 0.0
        }
        prevAllowedHeartMetrics = true

        // Run detection per-sample over the detection channel's new 64 Hz samples, each carrying
        // a regular sample-clock time. Non-detection channels carry no newSamples — they only
        // refresh the display streams. (Rare to get two beats in one 6-sample packet; the last
        // one wins for the event returned this call.)
        var heartEvent: MusePPGHeartEvent? = nil
        for s in streams.newSamples {
            if let ev = processDetectionSample(rawX: s.x, t: s.t) {
                heartEvent = ev
            }
        }

        return MusePPGResult(heartEvent: heartEvent, streams: streams)
    }

    //sub

    /// Runs the peak-detection state machine for a single 64 Hz sample.
    private func processDetectionSample(rawX: Double, t: Double) -> MusePPGHeartEvent? {

        // beat-smoothing EMA
        let x: Double
        if detectionInitialized {
            detectionSample += detectionAlpha * (rawX - detectionSample)
            x = detectionSample
        } else {
            detectionSample = rawX
            detectionInitialized = true
            x = rawX
            lastSample = rawX
            secondLastSample = rawX
            lastTimestamp = t
        }

        // update rolling stats for threshold
        updateRollingStats(x)
        let noiseStd = sqrt(max(rollingVar, 1e-9))
        // sanity floor only — prominence + interval do the real gating; this just rejects
        // degenerate bumps far below baseline during signal dropouts
        let dynamicThreshold = rollingMean - 1.0 * noiseStd

        _detPrintCounter += 1
        if _detPrintCounter % 128 == 0 {
            print(String(format: "PPG | x:%.3f  mean:%.3f  std:%.3f  thr:%.3f", x, rollingMean, noiseStd, dynamicThreshold))
        }

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

            // The local max is the previous sample. Refine its time to sub-sample precision by
            // fitting a parabola through (prev-prev, prev=peak, current). This trims the residual
            // 15.6ms grid quantization on top of removing the 94ms packet quantization + jitter.
            let peakTime = lastTimestamp
            let yL = secondLastSample
            let yP = lastSample
            let yR = x
            var refinedPeakTime = peakTime
            let denom = yL - 2.0 * yP + yR
            if denom < -1e-12 { // concave (true local max)
                var delta = 0.5 * (yL - yR) / denom
                if delta > 1.0 { delta = 1.0 } else if delta < -1.0 { delta = -1.0 }
                refinedPeakTime = peakTime + delta * ppgSampleInterval
            }

            let timeSinceLastBeat = refinedPeakTime - lastBeatTime
            // Fast floor when a real pulse is present, strict floor when the signal is flat
            // dropout (where dicrotic doubles slip past prominence/threshold).
            let refractoryFloor = noiseStd >= flatSignalStd ? refractoryFloorHealthy : refractoryFloorFlat
            let adaptiveMinimumInterval: Double
            if lastAcceptedBeatInterval > 0 {
                // Factor 0.45 + cap 0.50s lets the rate roughly double beat-to-beat (rest→exercise)
                // while the floor handles the absolute ceiling.
                adaptiveMinimumInterval = max(refractoryFloor, min(lastAcceptedBeatInterval * 0.45, 0.50))
            } else {
                adaptiveMinimumInterval = refractoryFloor
            }

            let peakProminence = candidatePeakValue - lastTroughValue
            // measured on Muse 2/S: real beats show prominence 0.015–0.28, noise wiggles ≤0.010.
            // mostly-flat floor — heavy std scaling inflated the requirement right after motion
            // transients and blocked real beats on the descent
            //
            // Rhythm-aware relaxation: when a beat is overdue relative to the established
            // rhythm (e.g. head-lean drops contact pressure and collapses pulse amplitude),
            // drop the floor so weak-but-real beats are caught. Scoped to the overdue window
            // only, so steady-state detection is unaffected. The interval gate still prevents
            // double-counts.
            let overdue = lastAcceptedBeatInterval > 0 &&
                          timeSinceLastBeat > lastAcceptedBeatInterval * 1.3
            let promFloor = overdue ? 0.006 : 0.012
            let minProminence = max(promFloor, noiseStd * 0.2)

            let passInterval   = timeSinceLastBeat >= adaptiveMinimumInterval
            let passThreshold  = candidatePeakValue > dynamicThreshold
            let passProminence = peakProminence >= minProminence

            if passInterval && passThreshold && passProminence {

                // a gap-spanning interval (missed beats / dropout) isn't a real beat-to-beat
                // interval — storing it inflates the adaptive minimum to its cap and can block
                // the first beat after the gap at high heart rates
                lastAcceptedBeatInterval = timeSinceLastBeat < 1.8 ? timeSinceLastBeat : 0.0
                lastBeatTime = refinedPeakTime

                let ppgAnalysis = _ppgAnalyzer.update(
                    at: refinedPeakTime,
                    amplitude: sensor.rawAmplitude
                )

                let bpm = ppgAnalysis.bpm
                print(String(format: "BEAT | t:%.3f  interval:%.3fs  bpm:%.0f  hrv:%.0f raw:%.0f rmssd:%.0f rawRMSSD:%.0f nn:%d nnOK:%@ rel:%.2f  peak:%.3f  prom:%.3f  thr:%.3f",
                             refinedPeakTime, timeSinceLastBeat, bpm,
                             ppgAnalysis.sdnnMs,
                             ppgAnalysis.rawSdnnMs,
                             ppgAnalysis.rmssdMs,
                             ppgAnalysis.rawRmssdMs,
                             ppgAnalysis.nnCount,
                             ppgAnalysis.didAcceptNNInterval ? "Y" : "N",
                             ppgAnalysis.nnRelDiff,
                             candidatePeakValue, peakProminence, dynamicThreshold))

                heartEvent = MusePPGHeartEvent(
                    bpm: bpm,
                    pulseStrength: ppgAnalysis.beatStrength,
                    sdnn: ppgAnalysis.sdnnMs
                )
            } else {
                var reasons: [String] = []
                if !passInterval   { reasons.append(String(format: "interval(%.3f<%.3f)", timeSinceLastBeat, adaptiveMinimumInterval)) }
                if !passThreshold  { reasons.append(String(format: "threshold(%.3f<%.3f)", candidatePeakValue, dynamicThreshold)) }
                if !passProminence { reasons.append(String(format: "prominence(%.3f<%.3f)", peakProminence, minProminence)) }
                print("MISS | \(reasons.joined(separator: " ")) | peak:\(String(format: "%.3f", candidatePeakValue))")
            }
        }

        wasRising = rising
        secondLastSample = lastSample
        lastSample = x
        lastTimestamp = t

        return heartEvent
    }

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
