struct PPGAnalysisPacket {
    var bpm: Double        // bpm (smoothed)
    var sdnnMs: Double     // SDNN in ms
    var rmssdMs: Double    // RMSSD in ms
    var hrvIndex: Double   // 0–100 scaled HRV index (from RMSSD)
    var pulseAmp: Double   // latest beat amplitude (arb units)
    
    init(bpm: Double, sdnnMs: Double, rmssdMs: Double, hrvIndex: Double, pulseAmp:Double) {
        self.bpm = bpm
        self.sdnnMs = sdnnMs
        self.rmssdMs = rmssdMs
        self.hrvIndex = hrvIndex
        self.pulseAmp = pulseAmp
    }
}

class PPGAnalyzer {
    
    private var prevTimestamp: Double = 0
    private var bpms = RingBuffer<Double>(capacity: 100)
    private var nnIntervals = RingBuffer<Double>(capacity: 60) // seconds
    private let minIntervalsForHRV = 12
    private let initialHRVClampIntervals = 20
    private let initialSdnnClampMs: Double = 110.0
    private let initialRmssdClampMs: Double = 100.0
    private let hrvRiseSmoothing: Double = 0.12
    private let hrvFallSmoothing: Double = 0.28
    private var publishedSdnnMs: Double = 0.0
    private var publishedRmssdMs: Double = 0.0

    internal func update(at timestamp: Double, peak: Double, trough: Double) -> PPGAnalysisPacket {
        
        let beatLength = timestamp - prevTimestamp // seconds
        //print("beat length", beatLength)
        
        // Accept only plausible NN intervals based on absolute bounds
        if beatLength > 0.4 && beatLength < 1.8 { // ~40–180 bpm
            // Optional: reject outliers relative to recent median
            if nnIntervals.count >= 5 {
                let recent = Array(nnIntervals.toArray().suffix(20)) // last 20 beats
                let sorted = recent.sorted()
                let median = sorted[sorted.count / 2]
                let relDiff = abs(beatLength - median) / median
                if relDiff < 0.15 { // accept only if within 15% of recent median
                    nnIntervals.append(beatLength)
                }
            } else {
                nnIntervals.append(beatLength)
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
            var diffsSqSum = 0.0
            var diffCount = 0
            for i in 1..<arr.count {
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
        
        // --- pulse amplitude (beat to beat) ---
        let pulseAmp = peak - trough
        
        // --- BPM (smoothed) ---
        let currBpm = 60.0 / beatLength
        bpms.append(currBpm)
        let arrBpm = bpms.toArray()
        let averageBpm = arrBpm.reduce(0, +) / Double(arrBpm.count)
        
        prevTimestamp = timestamp
        
        return PPGAnalysisPacket(
            bpm: averageBpm,
            sdnnMs: sdnnMs,
            rmssdMs: rmssdMs,
            hrvIndex: hrvIndex,
            pulseAmp: pulseAmp
        )
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
