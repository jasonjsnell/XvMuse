struct PPGAnalysisPacket {
    var bpm: Double        // bpm (smoothed)
    var sdnnMs: Double     // SDNN in ms
    var rmssdMs: Double    // RMSSD in ms
    var hrvIndex: Double   // 0–100 scaled HRV index (from RMSSD)
    var hrvBaseline: Double // 0–100 HR-corrected HRV: 50 = personal expected RMSSD at this HR
    var beatStrength: Double // 0–1 kick driver: flipped perfusion blended with normalized BPM
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
        hrvBaseline: Double,
        beatStrength: Double,
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
        self.hrvBaseline = hrvBaseline
        self.beatStrength = beatStrength
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
    private var publishedPerfusion: Double = 0.0
    private let perfusionSmoothing: Double = 0.2

    // Blended beat strength (kick-drum driver). Optical amplitude is FLIPPED — it's high when
    // calm/vasodilated, low under exertion/vasoconstriction — then blended with normalized BPM
    // so "working harder" reads louder, with BPM tempering the amplitude's signal-quality
    // confound (loose band / cold also drop amplitude).
    // Max matches the analyzer's own 0.4s NN bound (150 bpm) — the fastest rate this pipeline
    // can ever measure, so a maxed-out heart reads full scale instead of pinning at 83%.
    private let strengthBpmMin: Double = 60.0
    private let strengthBpmMax: Double = 150.0
    private let strengthAmpWeight: Double = 0.5 // 0 = all BPM, 1 = all flipped-amplitude

    /* HR-CORRECTED HRV: THE MASTER CURVE.

     RMSSD is mathematically entangled with heart rate — as HR rises, beat-to-beat variability
     shrinks roughly exponentially for mechanical reasons, so a falling RMSSD can mean "stress"
     or just "heart sped up". Following Rudics et al. (Biomedicines 2025, 13:81), we learn this
     wearer's own RMSSD-vs-HR relationship (the "master curve") and report variability RELATIVE
     to it: how variable is this heart compared to what is normal FOR IT at this exact rate.

     The curve is a set of 5-BPM bins over 40-140 BPM, each holding a running mean of ln(RMSSD)
     observed at that rate. ln, because RMSSD-vs-HR is close to log-linear, ratios are the
     natural distance measure, and PPG outliers pull a log-mean far less than a linear one.
     The output index is 50 + 50·(lnRMSSD − expected)/ln2, clamped 0-100: 50 = right on the
     wearer's curve, 100 = twice the expected variability (relaxation), 0 = half (stress).
     Neutral 50 is reported until the curve has enough beats to be trustworthy.

     The curve can be snapshotted and restored, so the app can persist it across sessions —
     the longer it accumulates, the wider its HR coverage and the better the correction. */
    private let mcMinBpm: Double = 40.0
    private let mcBinWidthBpm: Double = 5.0
    private let mcBinCount: Int = 20                 // 40-140 BPM
    /* Each bin is a RUNNING MEAN (alpha = 1/n) with this floor on alpha once the bin matures.
     A fixed per-beat alpha would make the "baseline" a ~30-beat tracker of the current state —
     a sustained relaxation would teach the curve its own relaxed values within a minute and the
     index would self-cancel back to 50 while the state persisted. The running mean instead
     converges on the average across every visit to that heart rate. The floor keeps old data
     from freezing the curve forever, but must stay far slower than a session state: at 0.0003
     the mature half-life is ~2300 in-bin beats (~35 min at 65 BPM), so a 30-minute relaxation
     still keeps most of its index elevation while the curve absorbs it only gradually across
     sessions. (0.002 was measurably too fast — a 10-minute state lost ~70% of its reading.) */
    private let mcSmoothingFloor: Double = 0.0003
    private let mcMinTotalSamples: Int = 30          // beats before the index leaves neutral
    private let mcFullScaleLnRatio: Double = 0.693   // ln2: double/half spans the full index
    private var mcLnRmssd: [Double]                  // per-bin EMA of ln(RMSSD ms)
    private var mcCounts: [Double]                   // per-bin sample counts (Double for snapshots)

    init() {
        mcLnRmssd = Array(repeating: 0.0, count: mcBinCount)
        mcCounts = Array(repeating: 0.0, count: mcBinCount)
    }

    /* Performer's manual heart-rate offset, set from the diagnostic UI.

     The strengthBpmMax ceiling describes how fast a MEASURED heart can plausibly run. The offset
     is a deliberate override — someone reaching for more output than their resting body is
     giving them — so it is added on top of the capped measurement rather than being capped with
     it. Without that split, every widening of the ceiling would silently weaken the offset. */
    internal var heartRateOffsetBPM: Double = 0.0

    internal func update(at timestamp: Double, amplitude: Double) -> PPGAnalysisPacket {
        
        let beatLength = timestamp - prevTimestamp // seconds
        //print("beat length", beatLength)
        var didAcceptNNInterval = false
        var nnRelDiff = 0.0
        
        // Accept only plausible NN intervals based on absolute bounds. prevTimestamp > 0 skips the
        // first beat, whose beatLength = timestamp − 0 is a bogus interval (was reading ~90 bpm).
        if prevTimestamp > 0 && beatLength > 0.4 && beatLength < 1.8 { // ~33–150 bpm
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
        
        // --- SDNN (ms), detrended ---
        // Plain SDNN over a sliding window inflates whenever the heart rate is drifting (the
        // launch settle-down, post-cardio recovery): the monotonic ramp registers as "spread."
        // Subtract the linear trend first so SDNN reflects true variability (incl. breathing
        // RSA) regardless of a slow rate drift. At a steady rate the trend is flat → unchanged.
        var sdnnMs: Double = 0.0
        if nnIntervals.count >= minIntervalsForHRV {
            let sdSec = detrendedStdDev(nnIntervals.toArray())
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

        // --- HR-corrected HRV vs the personal master curve ---
        // Feed the curve only on freshly-accepted, past-warm-up beats so rejected detections
        // and the clamped startup window never bend the baseline.
        let bpmForCurve = bpms.toArray().isEmpty ? 0.0 : bpms.toArray().reduce(0, +) / Double(bpms.count)
        if didAcceptNNInterval,
           nnIntervals.count >= initialHRVClampIntervals,
           rmssdMs > 1.0,
           bpmForCurve > 0 {
            feedMasterCurve(bpm: bpmForCurve, lnRmssd: log(rmssdMs))
        }
        let hrvBaseline = hrvBaselineIndex(bpm: bpmForCurve, rmssdMs: rmssdMs)
        logHRVIfDue(bpm: bpmForCurve, rmssdMs: rmssdMs, index: hrvBaseline)

        // --- perfusion (peripheral blood-volume pulse amplitude, raw optical envelope 0–1).
        // High when calm/warm/vasodilated, low under exertion/vasoconstriction. Stays local —
        // only the blended beatStrength leaves this class.
        if publishedPerfusion == 0.0 {
            publishedPerfusion = amplitude
        } else {
            publishedPerfusion += perfusionSmoothing * (amplitude - publishedPerfusion)
        }
        let perfusion = publishedPerfusion

        // --- BPM (smoothed) ---
        let bpmArray = bpms.toArray()
        // 65 = resting-ish seed shown before any real beat-to-beat interval lands (was 90).
        let averageBpm = bpmArray.isEmpty ? 65.0 : bpmArray.reduce(0, +) / Double(bpmArray.count)

        // --- blended beat strength (kick driver) ---
        // Flip perfusion (guarded: no-data 0 stays 0, not a full-blast 1), normalize BPM to
        // 0–1 over the resting→exertion band, then weighted-blend the two.
        let flippedPerfusion = perfusion > 0.0 ? (1.0 - perfusion) : 0.0
        let drivenBpm = min(averageBpm, strengthBpmMax) + heartRateOffsetBPM
        let normBpm = max(0.0, min(1.0, (drivenBpm - strengthBpmMin) / (strengthBpmMax - strengthBpmMin)))
        let beatStrength = strengthAmpWeight * flippedPerfusion + (1.0 - strengthAmpWeight) * normBpm

        // print(String(format: "  STR | str:%.2f  perfusion:%.2f (flip:%.2f)  bpm:%.0f",
        //              beatStrength, perfusion, flippedPerfusion, averageBpm))

        prevTimestamp = timestamp

        return PPGAnalysisPacket(
            bpm: averageBpm,
            sdnnMs: sdnnMs,
            rmssdMs: rmssdMs,
            hrvIndex: hrvIndex,
            hrvBaseline: hrvBaseline,
            beatStrength: beatStrength,
            rawSdnnMs: rawSdnnMs,
            rawRmssdMs: rawRmssdMs,
            nnCount: nnIntervals.count,
            didAcceptNNInterval: didAcceptNNInterval,
            nnRelDiff: nnRelDiff
        )
    }

    /// Standard deviation of the array after removing its linear trend (least-squares line).
    /// Strips slow heart-rate drift (settle-down, recovery ramp) that would otherwise inflate
    /// SDNN, leaving the true beat-to-beat + respiratory variability.
    private func detrendedStdDev(_ arr: [Double]) -> Double {
        let n = arr.count
        guard n >= 3 else { return Number.getStandardDeviation(ofArray: arr) }
        let nD = Double(n)
        let sumX = (nD - 1.0) * nD / 2.0
        let sumX2 = (nD - 1.0) * nD * (2.0 * nD - 1.0) / 6.0
        var sumY = 0.0, sumXY = 0.0
        for i in 0..<n {
            sumY += arr[i]
            sumXY += Double(i) * arr[i]
        }
        let denom = nD * sumX2 - sumX * sumX
        guard abs(denom) > 1e-12 else { return Number.getStandardDeviation(ofArray: arr) }
        let slope = (nD * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / nD
        var sumSq = 0.0
        for i in 0..<n {
            let resid = arr[i] - (slope * Double(i) + intercept)
            sumSq += resid * resid
        }
        return sqrt(sumSq / nD)
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

    //deliberately leaves the master curve alone: it is the wearer's baseline, not session state
    internal func resetMetrics() {
        bpms = RingBuffer<Double>(capacity: 12)
        nnIntervals = RingBuffer<Double>(capacity: 60)
        nnContiguous = RingBuffer<Int>(capacity: 60)
        rejectedPrevNN = false
        nnOutlierRun = 0
        bpmOutlierRun = 0
        publishedSdnnMs = 0.0
        publishedRmssdMs = 0.0
        publishedPerfusion = 0.0
        prevTimestamp = 0
    }

    // MARK: Master curve (HR-corrected HRV)

    private func mcBinIndex(bpm: Double) -> Int {
        let index = Int((bpm - mcMinBpm) / mcBinWidthBpm)
        return min(max(index, 0), mcBinCount - 1)
    }

    private func feedMasterCurve(bpm: Double, lnRmssd: Double) {
        let bin = mcBinIndex(bpm: bpm)
        if mcCounts[bin] == 0 {
            mcLnRmssd[bin] = lnRmssd
        } else {
            //running mean: each new beat carries 1/n weight, floored so the curve never fully rigidifies
            let alpha = max(1.0 / (mcCounts[bin] + 1.0), mcSmoothingFloor)
            mcLnRmssd[bin] += alpha * (lnRmssd - mcLnRmssd[bin])
        }
        mcCounts[bin] += 1
    }

    /* Expected ln(RMSSD) at this heart rate. Interpolates between the nearest occupied bins on
     each side; at the edges of coverage it extends the outermost bin flat. A single-bin curve
     is still usable — it just reads as "vs your overall typical variability" until more of the
     HR range has been visited. */
    private func expectedLnRmssd(bpm: Double) -> Double? {
        let occupied = (0..<mcBinCount).filter { mcCounts[$0] > 0 }
        guard !occupied.isEmpty else { return nil }

        let bin = mcBinIndex(bpm: bpm)
        if mcCounts[bin] > 0 { return mcLnRmssd[bin] }

        let below = occupied.last(where: { $0 < bin })
        let above = occupied.first(where: { $0 > bin })
        switch (below, above) {
        case let (.some(b), .some(a)):
            let t = Double(bin - b) / Double(a - b)
            return mcLnRmssd[b] + t * (mcLnRmssd[a] - mcLnRmssd[b])
        case let (.some(b), nil):
            return mcLnRmssd[b]
        case let (nil, .some(a)):
            return mcLnRmssd[a]
        default:
            return nil
        }
    }

    private func hrvBaselineIndex(bpm: Double, rmssdMs: Double) -> Double {
        let total = mcCounts.reduce(0, +)
        guard total >= Double(mcMinTotalSamples),
              rmssdMs > 1.0,
              bpm > 0,
              let expected = expectedLnRmssd(bpm: bpm) else {
            return 50.0 // neutral until the curve (or this beat) is trustworthy
        }
        let lnRatio = log(rmssdMs) - expected
        let index = 50.0 + (lnRatio / mcFullScaleLnRatio) * 50.0
        return min(max(index, 0.0), 100.0)
    }

    ///HRV master-curve logging, ~every 5 s. Off — flip on when testing the HR correction.
    static let logHRV = false
    private var lastHRVLogTime: TimeInterval = 0

    private func logHRVIfDue(bpm: Double, rmssdMs: Double, index: Double) {
        guard Self.logHRV else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastHRVLogTime >= 5.0 else { return }
        lastHRVLogTime = now

        let occupied = mcCounts.filter { $0 > 0 }.count
        let total = Int(mcCounts.reduce(0, +))
        let expected = expectedLnRmssd(bpm: bpm)
        let expectedMs = expected.map { exp($0) }
        print(String(
            format: "HRV | bpm %3.0f | rmssd %5.1fms | expected %@ | index %3.0f | bins %d/%d (%d beats)",
            bpm,
            rmssdMs,
            expectedMs.map { String(format: "%5.1fms", $0) } ?? "  --  ",
            index,
            occupied, mcBinCount, total
        ))
    }

    /* Persistence: first 20 values are the per-bin ln(RMSSD) EMAs, next 20 the sample counts.
     Restoring merges nothing — it replaces, so restore BEFORE the session generates data. */
    internal func masterCurveSnapshot() -> [Double] {
        return mcLnRmssd + mcCounts
    }

    internal func restoreMasterCurve(_ snapshot: [Double]) {
        guard snapshot.count == mcBinCount * 2 else { return }
        let values = Array(snapshot[0..<mcBinCount])
        let counts = Array(snapshot[mcBinCount..<(mcBinCount * 2)])
        guard values.allSatisfy({ $0.isFinite }), counts.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        mcLnRmssd = values
        mcCounts = counts
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
