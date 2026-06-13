struct PPGAnalysisPacket {
    var bpm: Double        // bpm (smoothed)
    var sdnnMs: Double     // SDNN in ms
    var rmssdMs: Double    // RMSSD in ms
    var hrvIndex: Double   // 0–100 scaled HRV index (from RMSSD)
    var pulseAmp: Double   // latest beat amplitude (arb units)
    var rawSdnnMs: Double
    var rawRmssdMs: Double
    var nnCount: Int
    var didAcceptNNInterval: Bool
    var nnRelDiff: Double
    
    init(
        bpm: Double,
        sdnnMs: Double,
        rmssdMs: Double,
        hrvIndex: Double,
        pulseAmp: Double,
        rawSdnnMs: Double,
        rawRmssdMs: Double,
        nnCount: Int,
        didAcceptNNInterval: Bool,
        nnRelDiff: Double
    ) {
        self.bpm = bpm
        self.sdnnMs = sdnnMs
        self.rmssdMs = rmssdMs
        self.hrvIndex = hrvIndex
        self.pulseAmp = pulseAmp
        self.rawSdnnMs = rawSdnnMs
        self.rawRmssdMs = rawRmssdMs
        self.nnCount = nnCount
        self.didAcceptNNInterval = didAcceptNNInterval
        self.nnRelDiff = nnRelDiff
    }
}

class PPGAnalyzer {
    
    private var prevTimestamp: Double = 0
    private var bpms = RingBuffer<Double>(capacity: 12) // ~10s at 70 bpm
    private var nnIntervals = RingBuffer<Double>(capacity: 60) // seconds
    // parallel to nnIntervals: true if this interval is time-contiguous with the previous
    // stored one (no beat rejected between them). RMSSD skips diffs across a gap.
    private var nnContiguous = RingBuffer<Int>(capacity: 60)
    private var rejectedPrevNN = false
    // Consecutive outlier rejections. A sustained run means the heart rate genuinely shifted to
    // a new regime (sat down at 110 after exercise, exercise onset) and the buffer is stale —
    // rebuild around the new rate instead of locking on the old median forever.
    private var nnOutlierRun = 0
    private var bpmOutlierRun = 0
    private let nnRegimeRun = 6
    private let bpmRegimeRun = 4
    private let bootstrapRelTolerance = 0.30
    private let minIntervalsForHRV = 12
    private let initialHRVClampIntervals = 20
    private let initialSdnnClampMs: Double = 110.0
    private let initialRmssdClampMs: Double = 100.0
    private let hrvRiseSmoothing: Double = 0.12
    private let hrvFallSmoothing: Double = 0.28
    private var publishedSdnnMs: Double = 0.0
    private var publishedRmssdMs: Double = 0.0
    private var publishedAmp: Double = 0.0
    private let ampSmoothing: Double = 0.2

    internal func update(at timestamp: Double, amplitude: Double) -> PPGAnalysisPacket {
        
        let beatLength = timestamp - prevTimestamp // seconds
        //print("beat length", beatLength)
        var didAcceptNNInterval = false
        var nnRelDiff = 0.0
        
        // Accept only plausible NN intervals based on absolute bounds
        if beatLength > 0.4 && beatLength < 1.8 { // ~40–180 bpm
            let instantBpm = 60.0 / beatLength

            // --- BPM buffer: reject gross outliers, but unstick on a sustained real HR change.
            // The 40% gate stops a single gap-beat (e.g. 34 bpm) polluting the average, but a
            // stale median (resting 70 in the buffer when you've sat down at 110) rejected every
            // real beat and locked the display. A sustained run of rejections = real shift.
            let bpmHistory = bpms.toArray()
            if bpmHistory.count >= 5 {
                let sorted = Array(bpmHistory.suffix(20)).sorted()
                let median = sorted[sorted.count / 2]
                if abs(instantBpm - median) / median < 0.40 {
                    bpms.append(instantBpm)
                    bpmOutlierRun = 0
                } else {
                    bpmOutlierRun += 1
                    if bpmOutlierRun >= bpmRegimeRun {
                        bpms = RingBuffer<Double>(capacity: 12)
                        bpms.append(instantBpm)
                        bpmOutlierRun = 0
                    }
                }
            } else {
                bpms.append(instantBpm)
            }

            // --- NN intervals (HRV). 15% median gate rejects detector artifacts; a sustained
            // run of rejections means the rate regime changed (post-workout, exercise onset) and
            // the window is stale — rebuild so SDNN reflects the new rate, not the old-vs-new
            // spread (which read as a falsely-high, clamped 110ms).
            if nnIntervals.count >= 5 {
                let recent = Array(nnIntervals.toArray().suffix(20)) // last 20 beats
                let sorted = recent.sorted()
                let median = sorted[sorted.count / 2]
                let relDiff = abs(beatLength - median) / median
                nnRelDiff = relDiff
                if relDiff < 0.15 {
                    nnIntervals.append(beatLength)
                    nnContiguous.append(rejectedPrevNN ? 0 : 1) // false if a beat was rejected since last accept
                    rejectedPrevNN = false
                    didAcceptNNInterval = true
                    nnOutlierRun = 0
                } else {
                    rejectedPrevNN = true
                    nnOutlierRun += 1
                    if nnOutlierRun >= nnRegimeRun {
                        rebuildNN(seed: beatLength)
                        didAcceptNNInterval = true
                    }
                }
            } else if let lastNN = nnIntervals.toArray().last {
                // Bootstrap (cold start / just after a rebuild): no median yet, but still reject
                // implausible doubled/gap intervals vs the previous accepted one — otherwise a
                // single missed-beat interval seeds the buffer and inflates SDNN for ~60 beats
                // (the junk that masqueraded as 110ms after every reset).
                let relDiff = abs(beatLength - lastNN) / lastNN
                nnRelDiff = relDiff
                if relDiff < bootstrapRelTolerance {
                    nnIntervals.append(beatLength)
                    nnContiguous.append(rejectedPrevNN ? 0 : 1)
                    rejectedPrevNN = false
                    didAcceptNNInterval = true
                    nnOutlierRun = 0
                } else {
                    rejectedPrevNN = true
                    nnOutlierRun += 1
                    if nnOutlierRun >= nnRegimeRun { // seed itself was junk — rebuild around current
                        rebuildNN(seed: beatLength)
                        didAcceptNNInterval = true
                    }
                }
            } else {
                // very first interval — nothing to vet against
                nnIntervals.append(beatLength)
                nnContiguous.append(1)
                rejectedPrevNN = false
                didAcceptNNInterval = true
            }
        }
        
        // --- SDNN (ms) ---
        var sdnnMs: Double = 0.0
        if nnIntervals.count >= minIntervalsForHRV {
            let sdSec = Number.getStandardDeviation(ofArray: nnIntervals.toArray())
            sdnnMs = sdSec * 1000.0
            if sdnnMs.isInfinite || sdnnMs.isNaN { sdnnMs = 0.0 }
        }
        
        // --- RMSSD (ms) ---
        var rmssdMs: Double = 0.0
        if nnIntervals.count >= minIntervalsForHRV {
            let arr = nnIntervals.toArray()
            let contig = nnContiguous.toArray()
            var diffsSqSum = 0.0
            var diffCount = 0
            for i in 1..<arr.count {
                // skip a successive diff that spans a rejected beat — arr[i] and arr[i-1]
                // are adjacent in the buffer but weren't consecutive in time
                if i < contig.count && contig[i] == 0 { continue }
                let diff = arr[i] - arr[i - 1]
                diffsSqSum += diff * diff
                diffCount += 1
            }
            if diffCount > 0 {
                let meanSq = diffsSqSum / Double(diffCount)
                let rmssdSec = sqrt(meanSq)
                rmssdMs = rmssdSec * 1000.0
            }
        }
        if rmssdMs.isInfinite || rmssdMs.isNaN { rmssdMs = 0.0 }

        let rawSdnnMs = sdnnMs
        let rawRmssdMs = rmssdMs

        sdnnMs = stabilizeHRV(
            raw: sdnnMs,
            published: publishedSdnnMs,
            sampleCount: nnIntervals.count,
            initialClamp: initialSdnnClampMs
        )
        rmssdMs = stabilizeHRV(
            raw: rmssdMs,
            published: publishedRmssdMs,
            sampleCount: nnIntervals.count,
            initialClamp: initialRmssdClampMs
        )
        publishedSdnnMs = sdnnMs
        publishedRmssdMs = rmssdMs
        
        
        // --- 0–100 HRV index from RMSSD ---
        let minHRV: Double = 10.0
        let maxHRV: Double = 100.0
        let clamped = max(minHRV, min(maxHRV, rmssdMs))
        let hrvIndex = (clamped - minHRV) / (maxHRV - minHRV) * 100.0
        
        // --- pulse amplitude (raw optical envelope, pre-normalization) ---
        if publishedAmp == 0.0 {
            publishedAmp = amplitude
        } else {
            publishedAmp += ampSmoothing * (amplitude - publishedAmp)
        }
        let pulseAmp = publishedAmp
        
        // --- BPM (smoothed) ---
        let bpmArray = bpms.toArray()
        let averageBpm = bpmArray.isEmpty ? 0.0 : bpmArray.reduce(0, +) / Double(bpmArray.count)
        
        prevTimestamp = timestamp
        
        return PPGAnalysisPacket(
            bpm: averageBpm,
            sdnnMs: sdnnMs,
            rmssdMs: rmssdMs,
            hrvIndex: hrvIndex,
            pulseAmp: pulseAmp,
            rawSdnnMs: rawSdnnMs,
            rawRmssdMs: rawRmssdMs,
            nnCount: nnIntervals.count,
            didAcceptNNInterval: didAcceptNNInterval,
            nnRelDiff: nnRelDiff
        )
    }

    // Drop the stale NN window and reseed with the current interval. Used when a sustained run
    // of outliers shows the heart rate moved to a new regime. publishedSdnn is left alone so the
    // displayed value eases toward the new (low) SDNN rather than snapping.
    private func rebuildNN(seed: Double) {
        nnIntervals = RingBuffer<Double>(capacity: 60)
        nnContiguous = RingBuffer<Int>(capacity: 60)
        nnIntervals.append(seed)
        nnContiguous.append(1)
        rejectedPrevNN = false
        nnOutlierRun = 0
    }

    internal func resetMetrics() {
        bpms = RingBuffer<Double>(capacity: 12)
        nnIntervals = RingBuffer<Double>(capacity: 60)
        nnContiguous = RingBuffer<Int>(capacity: 60)
        rejectedPrevNN = false
        nnOutlierRun = 0
        bpmOutlierRun = 0
        publishedSdnnMs = 0.0
        publishedRmssdMs = 0.0
        publishedAmp = 0.0
        prevTimestamp = 0
    }

    private func stabilizeHRV(raw: Double, published: Double, sampleCount: Int, initialClamp: Double) -> Double {
        guard sampleCount >= minIntervalsForHRV, raw > 0 else { return 0.0 }

        var candidate = raw

        if sampleCount < initialHRVClampIntervals {
            candidate = min(candidate, initialClamp)
        }

        guard published > 0 else { return candidate }

        let maxAllowedRise = published + max(12.0, published * 0.25)
        candidate = min(candidate, maxAllowedRise)

        let smoothing = candidate > published ? hrvRiseSmoothing : hrvFallSmoothing
        return (published * (1.0 - smoothing)) + (candidate * smoothing)
    }
}
