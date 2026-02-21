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
    private var bpms: [Double] = []
    private var nnIntervals: [Double] = [] // seconds
    private let BPM_HISTORY_LENGTH_MAX = 100
    private let HRV_HISTORY_LENGTH_MAX = 60 // 600
    
    private var pulseAmplitudes: [Double] = []
    private var latestPulseAmp:Double = 0
    
    // --- pulse amplitude & respiration ---
    private struct AmpSample {
        let t: Double
        let amp: Double
    }
    private var ampSeries: [AmpSample] = []
    private let AMP_HISTORY_SEC: Double = 60.0 // window for respiration
    
    internal func update(at timestamp: Double, peak: Double, trough: Double) -> PPGAnalysisPacket {
        
        let beatLength = timestamp - prevTimestamp // seconds
        print("beat length", beatLength)
        
        // Accept only plausible NN intervals based on absolute bounds
        if beatLength > 0.4 && beatLength < 1.8 { // ~40–180 bpm
            // Optional: reject outliers relative to recent median
            if nnIntervals.count >= 5 {
                let recent = nnIntervals.suffix(20) // last 20 beats
                let sorted = recent.sorted()
                let median = sorted[sorted.count / 2]
                let relDiff = abs(beatLength - median) / median
                if relDiff < 0.15 { // accept only if within 15% of recent median
                    nnIntervals.append(beatLength)
                }
            } else {
                nnIntervals.append(beatLength)
            }

            
            if nnIntervals.count > HRV_HISTORY_LENGTH_MAX {
                nnIntervals.removeFirst()
            }
        }
        
        // --- SDNN (ms) ---
        var sdnnMs: Double = 0.0
        if nnIntervals.count > 1 {
            let sdSec = Number.getStandardDeviation(ofArray: nnIntervals)
            sdnnMs = sdSec * 1000.0
            if sdnnMs.isInfinite || sdnnMs.isNaN { sdnnMs = 0.0 }
        }
        
        // --- RMSSD (ms) ---
        var rmssdMs: Double = 0.0
        if nnIntervals.count > 2 {
            var diffsSqSum = 0.0
            var diffCount = 0
            for i in 1..<nnIntervals.count {
                let diff = nnIntervals[i] - nnIntervals[i - 1]
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
        
        
        // --- 0–100 HRV index from RMSSD ---
        let minHRV: Double = 10.0
        let maxHRV: Double = 100.0
        let clamped = max(minHRV, min(maxHRV, rmssdMs))
        let hrvIndex = (clamped - minHRV) / (maxHRV - minHRV) * 100.0
        
        // --- pulse amplitude (beat to beat) ---
        let pulseAmp = peak - trough
        ampSeries.append(AmpSample(t: timestamp, amp: pulseAmp))
        // drop samples older than AMP_HISTORY_SEC
        while let first = ampSeries.first,
              timestamp - first.t > AMP_HISTORY_SEC {
            ampSeries.removeFirst()
        }
        
        
        // --- BPM (smoothed) ---
        let currBpm = 60.0 / beatLength
        bpms.append(currBpm)
        if bpms.count > BPM_HISTORY_LENGTH_MAX {
            bpms.removeFirst()
        }
        let averageBpm = bpms.reduce(0, +) / Double(bpms.count)
        
        prevTimestamp = timestamp
        
        return PPGAnalysisPacket(
            bpm: averageBpm,
            sdnnMs: sdnnMs,
            rmssdMs: rmssdMs,
            hrvIndex: hrvIndex,
            pulseAmp: pulseAmp
        )
    }
}
