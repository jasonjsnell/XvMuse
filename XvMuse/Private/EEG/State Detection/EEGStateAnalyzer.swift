//
//  EEGStateAnalyzer.swift
//  XvMuse
//

import Foundation

protocol EEGStateAnalyzerDelegate: AnyObject {
    func didReceiveBaselineProgress(_ progress: Double)
    func didReceiveBrainwaveState(meditation: Double, focus: Double, dreamy: Double)
}

/* Measures brainwave states from the pre-filtered detail spectrum.

 FLOW
   detail spectrum (already band-passed before the FFT, forehead sensors only)
     -> undo the filter's own frequency response
     -> reduce to three numbers: centroid, spread, total power
     -> compare each against this person's running baseline
     -> blend into focus / meditation / dreamy / quiet

 BASELINE
 There is no warm-up discard and no locked/unlocked gate. The baseline starts learning from the
 first clean sample and scores publish from the first clean sample. Early samples are weighted
 down rather than thrown away, because electrode contact is usually still settling, and the
 spread of each measurement is blended against a prior so a one-sample baseline is still safe to
 divide by. The result gets steadily more accurate instead of arriving all at once, so the
 collection window can be generous without the app feeling dead while it fills.

 Learning stops once the baseline is mature, otherwise it would slowly follow the user into
 whatever state they held and quietly re-zero their own scores. */

final class EEGStateAnalyzer {

    weak var delegate: EEGStateAnalyzerDelegate?

    //MARK: - Tunables

    //signal must be at least this clean before anything is measured or learned
    private let cleanThreshold: Double = 60.0

    //how often scores are published, and how hard they are smoothed
    private let publishInterval: TimeInterval = 0.25
    private let scoreSmoothing: Double = 0.18

    /* Early samples count, they just count less. Weight ramps from warmupMinimumWeight up to
     full over warmupRampSeconds of clean time. */
    private let warmupRampSeconds: TimeInterval = 15.0
    private let warmupMinimumWeight: Double = 0.25

    //clean seconds of observation before the baseline stops learning
    private let baselineMaturitySeconds: TimeInterval = 90.0

    /* Muscle tension above this blocks baseline learning, though scoring carries on against
     whatever baseline already exists. A clench blasts energy right across the spectrum, so even
     a few seconds of it would drag the personal normal somewhere it should never have gone —
     and unlike a bad score, a polluted baseline stays wrong for the rest of the session. */
    private let baselineTensionCeiling: Double = 40.0

    /* Prior strength, in the same units as accumulated sample weight (roughly seconds).
     Small, because it only needs to cover the first few seconds before real data takes over. */
    private let priorWeight: Double = 4.0

    //assumed spread of each measurement before the person's own variability is known
    private let priorCentroidSD: Double = 1.5   //Hz
    private let priorSpreadSD: Double = 0.8     //Hz
    private let priorLogPowerSD: Double = 0.30  //log10 units, so about a 2x swing

    //how far back the "is the centroid parked or wandering" judgement looks
    private let stabilityWindow: TimeInterval = 8.0

    //ignore bins the filter has pushed below half amplitude; correcting them amplifies noise
    private let minimumFilterResponse: Double = 0.5

    //MARK: - Diagnostics
    //set false to silence the per-second state log
    private let logStates: Bool = true
    private let logInterval: TimeInterval = 1.0
    private var lastLogTime: Date? = nil
    private let launchTime = Date()

    //MARK: - Signal quality

    private var latestEffectiveCleanPct: Double = 0.0
    private var latestTensionPct: Double = 0.0
    private let effectiveCleanRiseSmoothing: Double = 0.35
    private let effectiveCleanFallSmoothing: Double = 0.12

    //full-spectrum band levels in dB, used for dreamy only
    private var latestBands: BandBalance? = nil

    //MARK: - Detail window mapping

    private let usableBins: [Int]       //spectrum indices inside the trusted part of the band
    private let usableFreqs: [Double]   //centre frequency of each, in Hz
    private let compensation: [Double]  //1 / |H(f)|^2, undoes the band-pass filter's own shape

    //MARK: - Baseline

    private var centroidStat = WeightedStat()
    private var spreadStat = WeightedStat()
    private var logPowerStat = WeightedStat()
    private var cleanTimeAccum: TimeInterval = 0
    private var lastSampleTime: Date? = nil

    //MARK: - Stability

    private var recentCentroids: [(value: Double, timestamp: Date)] = []

    private var lastPublish: Date? = nil
    private let scorer = EEGStateScorer()

    //MARK: - Init

    init(
        sampleRate: Double = MuseConstants.SAMPLING_RATE,
        fftBins: Int = MuseConstants.EEG_FFT_BINS,
        lowHz: Double = MuseConstants.DETAIL_BANDPASS_LOW_HZ,
        highHz: Double = MuseConstants.DETAIL_BANDPASS_HIGH_HZ
    ) {
        let binWidthHz = sampleRate / Double(fftBins)

        /* Rebuild the same filter the detail spectrum was produced with, purely to read back its
         frequency response. The filter ramps rather than cuts, so bins near the edges of the band
         arrive quieter than the brain actually was there — without correcting for that, a centroid
         would largely be measuring the filter. */
        let filter = FFTFilter(sampleRate: sampleRate, lowCutHz: lowHz, highCutHz: highHz)

        var bins: [Int] = []
        var freqs: [Double] = []
        var comp: [Double] = []

        for bin in 0..<(fftBins / 2) {
            let hz = Double(bin) * binWidthHz
            guard hz >= lowHz, hz <= highHz else { continue }
            let magnitude = filter.magnitudeResponse(atHz: hz)
            guard magnitude >= minimumFilterResponse else { continue }
            bins.append(bin)
            freqs.append(hz)
            comp.append(1.0 / (magnitude * magnitude))
        }

        //fallback: if the filter turned out too soft to trust anywhere, measure the band flat
        if bins.count < 4 {
            bins.removeAll(); freqs.removeAll(); comp.removeAll()
            for bin in 0..<(fftBins / 2) {
                let hz = Double(bin) * binWidthHz
                guard hz >= lowHz, hz <= highHz else { continue }
                bins.append(bin)
                freqs.append(hz)
                comp.append(1.0)
            }
            print("⚠️ EEGStateAnalyzer: filter response too soft to compensate, measuring band flat")
        }

        usableBins = bins
        usableFreqs = freqs
        compensation = comp

        print("📐 EEGStateAnalyzer: detail window \(lowHz)-\(highHz) Hz, \(bins.count) usable bins")
    }

    //MARK: - Input

    func updateSignalQuality(clean: Double, tension: Double) {

        latestTensionPct = tension

        /* Muscle tension makes the spectrum look busier than the brain actually is, so it caps
         how clean the signal is allowed to count as rather than being handled separately. */
        let target: Double
        if tension > 75.0 {
            target = min(clean, 25.0)
        } else if tension > 60.0 {
            target = min(clean, 50.0)
        } else {
            target = clean
        }

        latestEffectiveCleanPct = asymSmooth(
            old: latestEffectiveCleanPct,
            new: target,
            rise: effectiveCleanRiseSmoothing,
            fall: effectiveCleanFallSmoothing
        )
    }

    /* Full-spectrum band levels in dB. Dreamy is scored from these rather than from the detail
     window, since theta sits below the detail window's low cutoff. Call before
     processDetailSpectrum; the stored values are used on the next publish. */
    func updateBands(
        delta: Double,
        theta: Double,
        alpha: Double,
        beta: Double,
        gamma: Double,
        quiet: Double
    ) {
        latestBands = BandBalance(
            delta: delta,
            theta: theta,
            alpha: alpha,
            beta: beta,
            gamma: gamma,
            quiet: quiet
        )
    }

    func processDetailSpectrum(_ spectrum: [Double]) {

        guard !spectrum.isEmpty, !usableBins.isEmpty else { return }

        let now = Date()
        let dt = lastSampleTime.map { now.timeIntervalSince($0) } ?? 0
        lastSampleTime = now

        guard latestEffectiveCleanPct >= cleanThreshold else { return }
        guard let features = measure(spectrum, at: now) else { return }

        //the same sample both teaches the baseline and produces a score
        learn(from: features, dt: dt)
        trackStability(features, now: now)
        publishIfDue(features, now: now)
    }

    func reset() {
        centroidStat.reset()
        spreadStat.reset()
        logPowerStat.reset()
        cleanTimeAccum = 0
        lastSampleTime = nil
        recentCentroids.removeAll()
        lastPublish = nil
        latestEffectiveCleanPct = 0
        latestTensionPct = 0
        latestBands = nil
        scorer.reset()
    }

    //MARK: - Measurement

    /* Reduce one spectrum to three independent numbers. Filter compensation happens here, so
     everything downstream is working with the spectrum the brain actually produced. */
    private func measure(_ spectrum: [Double], at now: Date) -> DetailFeatures? {

        var powers = [Double](repeating: 0, count: usableBins.count)
        var total = 0.0
        var weightedFrequency = 0.0

        for (i, bin) in usableBins.enumerated() {
            guard bin < spectrum.count else { continue }
            let power = max(0.0, spectrum[bin]) * compensation[i]
            powers[i] = power
            total += power
            weightedFrequency += power * usableFreqs[i]
        }

        guard total > 1e-12, total.isFinite else { return nil }

        //balance point of the distribution
        let centroid = weightedFrequency / total

        //width of the distribution around that balance point
        var variance = 0.0
        for (i, power) in powers.enumerated() {
            let offset = usableFreqs[i] - centroid
            variance += power * offset * offset
        }
        let spread = sqrt(max(0.0, variance / total))

        guard centroid.isFinite, spread.isFinite else { return nil }

        //power is log-distributed, so baseline statistics belong in log space
        return DetailFeatures(
            centroidHz: centroid,
            spreadHz: spread,
            logPower: log10(total + 1e-12),
            timestamp: now
        )
    }

    //MARK: - Baseline

    private func learn(from features: DetailFeatures, dt: TimeInterval) {

        guard cleanTimeAccum < baselineMaturitySeconds else { return }

        //a clench distorts the whole spectrum; sit those moments out rather than learning from them
        guard latestTensionPct < baselineTensionCeiling else { return }

        //clamp so a dropout or a backgrounded app doesn't dump a huge chunk of time in at once
        cleanTimeAccum += min(max(dt, 0.0), 0.5)

        let ramp = min(1.0, cleanTimeAccum / warmupRampSeconds)
        let weight = warmupMinimumWeight + ((1.0 - warmupMinimumWeight) * ramp)

        centroidStat.add(features.centroidHz, weight: weight)
        spreadStat.add(features.spreadHz, weight: weight)
        logPowerStat.add(features.logPower, weight: weight)

        delegate?.didReceiveBaselineProgress(baselineProgress)

        if cleanTimeAccum >= baselineMaturitySeconds {
            print(String(
                format: "✅ Baseline mature — centroid %.2f Hz (sd %.2f), spread %.2f Hz, logPower %.2f",
                centroidStat.mean,
                centroidStat.standardDeviation(priorSD: priorCentroidSD, priorWeight: priorWeight),
                spreadStat.mean,
                logPowerStat.mean
            ))
        }
    }

    private var baselineProgress: Double {
        min(100.0, (cleanTimeAccum / max(baselineMaturitySeconds, 1e-6)) * 100.0)
    }

    //MARK: - Stability

    private func trackStability(_ features: DetailFeatures, now: Date) {
        recentCentroids.append((features.centroidHz, now))
        let cutoff = now.addingTimeInterval(-stabilityWindow)
        recentCentroids.removeAll { $0.timestamp < cutoff }
    }

    /* How still the centroid has been holding, 0 (wandering) to 1 (parked), judged against this
     person's own normal variability rather than an absolute number of Hz. */
    private var centroidStability: Double {

        guard recentCentroids.count >= 4 else { return 0.5 }

        let values = recentCentroids.map { $0.value }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let recentSD = sqrt(variance)

        let personalSD = centroidStat.standardDeviation(
            priorSD: priorCentroidSD,
            priorWeight: priorWeight
        )

        let ratio = recentSD / max(personalSD, 1e-6)
        return clamp01(1.0 - ((ratio - 0.4) / 1.4))
    }

    //MARK: - Output

    private func publishIfDue(_ features: DetailFeatures, now: Date) {

        if let last = lastPublish, now.timeIntervalSince(last) < publishInterval { return }
        lastPublish = now

        let zCentroid = centroidStat.z(features.centroidHz, priorSD: priorCentroidSD, priorWeight: priorWeight)
        let zSpread = spreadStat.z(features.spreadHz, priorSD: priorSpreadSD, priorWeight: priorWeight)
        let zPower = logPowerStat.z(features.logPower, priorSD: priorLogPowerSD, priorWeight: priorWeight)

        let scores = scorer.applyStateScores(
            zCentroid: zCentroid,
            zPower: zPower,
            zSpread: zSpread,
            stability: centroidStability,
            bands: latestBands,
            tension: latestTensionPct,
            smoothing: scoreSmoothing
        )

        delegate?.didReceiveBrainwaveState(
            meditation: scores.meditation,
            focus: scores.focus,
            dreamy: scores.dreamy
        )

        logState(
            features: features,
            scores: scores,
            zCentroid: zCentroid,
            zSpread: zSpread,
            zPower: zPower,
            now: now
        )
    }

    /* Per-second diagnostic dump. Prints the inputs to every score alongside the scores, because
     a score on its own only says something is wrong, never why.

     Line 1 — the detail window: raw measurement, then how unusual it is for this person, which is
              what actually drives focus and meditation. Also baseline maturity, since early
              z-scores lean on the prior rather than on real evidence.
     Line 2 — the full spectrum band balance and the dreamy breakdown, split into the shape that
              says it looks drowsy and the credibility that says whether to believe it. */
    private func logState(
        features: DetailFeatures,
        scores: (meditation: Double, focus: Double, dreamy: Double),
        zCentroid: Double,
        zSpread: Double,
        zPower: Double,
        now: Date
    ) {
        guard logStates else { return }
        if let last = lastLogTime, now.timeIntervalSince(last) < logInterval { return }
        lastLogTime = now

        let elapsed = now.timeIntervalSince(launchTime)

        print(String(
            format: "🧠 t:%6.1f | foc:%3.0f med:%3.0f drm:%3.0f | cen:%5.2fHz z%+5.2f | spr:%5.2fHz z%+5.2f | pow z%+5.2f | stab:%4.2f | base:%3.0f%% | clean:%3.0f tens:%3.0f",
            elapsed,
            scores.focus, scores.meditation, scores.dreamy,
            features.centroidHz, zCentroid,
            features.spreadHz, zSpread,
            zPower,
            centroidStability,
            baselineProgress,
            latestEffectiveCleanPct,
            latestTensionPct
        ))

        if let bands = latestBands {
            print(String(
                format: "🌙 t:%6.1f | Δ%6.1f Θ%6.1f Α%6.1f Β%6.1f Γ%6.1f | quiet:%3.0f | shape:%4.2f × cred:%4.2f (fast:%4.2f still:%4.2f)",
                elapsed,
                bands.delta, bands.theta, bands.alpha, bands.beta, bands.gamma,
                bands.quiet,
                scorer.dreamyShape,
                scorer.dreamyCredibility,
                scorer.dreamyFastBands,
                scorer.dreamyStillness
            ))
        }
    }

    //MARK: - Helpers

    private func asymSmooth(old: Double, new: Double, rise: Double, fall: Double) -> Double {
        let factor = new > old ? clamp01(rise) : clamp01(fall)
        return (factor * new) + ((1.0 - factor) * old)
    }

    private func clamp01(_ x: Double) -> Double {
        max(0.0, min(1.0, x))
    }
}


//MARK: - ARCHIVED -

/* Previous state detection: relative band powers averaged into 10 second epochs, z-scored
 against a baseline that was locked after a 15 second warm-up discard plus 30 seconds of
 collection, with no scores at all until that finished. Replaced by the detail-window analyzer
 above. Kept for reference; nothing in the live path constructs it. */

protocol LegacyEEGStateAnalyzerDelegate: AnyObject {
    func didReceiveBaselineProgress(_ progress: Double)
    func didReceiveBrainwaveState(meditation: Double, focus: Double, dreamy: Double)
}

final class LegacyEEGStateAnalyzer {
    weak var delegate: LegacyEEGStateAnalyzerDelegate?

    private var latestCleanPct: Double = 0.0
    private var latestEffectiveCleanPct: Double = 0.0
    private let effectiveCleanRiseSmoothing: Double = 0.35
    private let effectiveCleanFallSmoothing: Double = 0.12

    private var latestFAAShift: Double? = nil
    private var baselinePhase: BaselinePhase = .idle

    private var warmupCleanAccum: TimeInterval = 0
    private var collectingCleanAccum: TimeInterval = 0
    private var lastSampleTime: Date? = nil

    private var warmupStartTime: Date? = nil
    private let warmupDuration: TimeInterval = 15.0
    private let collectingDuration: TimeInterval = 30.0
    private let epochDuration: TimeInterval = 10.0
    private var epochStartTime: Date? = nil

    private var epochSumDelta: Double = 0
    private var epochSumTheta: Double = 0
    private var epochSumAlpha: Double = 0
    private var epochSumBeta: Double = 0
    private var epochSumGamma: Double = 0
    private var epochSampleCount: Int = 0

    private var epochSumFAA: Double = 0
    private var epochFAASampleCount: Int = 0

    private var epochs: [EpochRel] = []

    private var baselineMean: (delta: Double, theta: Double, alpha: Double, beta: Double, gamma: Double) = (0,0,0,0,0)
    private var baselineStd:  (delta: Double, theta: Double, alpha: Double, beta: Double, gamma: Double) = (1,1,1,1,1)
    private var baselineFAAMean: Double? = nil
    private var baselineFAAStd: Double? = nil

    private var recentEpochs: [EpochZ] = []
    private let maxRecentEpochs = 5
    private var currentState: String? = nil

    private var liveBandSamples: [LiveBandSample] = []
    private let liveScoringWindow: TimeInterval = 2.5
    private let liveScoringInterval: TimeInterval = 0.25
    private var lastLiveScoringUpdate: Date? = nil
    private var lastEpochZDelta: Double = 0.0
    private var lastEpochZTheta: Double = 0.0
    private var lastEpochZAlpha: Double = 0.0
    private var lastEpochZBeta: Double = 0.0
    private var lastEpochFAAShift: Double? = nil

    private let scorer = LegacyEEGStateScorer()

    func updateSignalQuality(clean: Double, tension: Double) {
        latestCleanPct = clean

        let effectiveCleanTarget: Double
        if tension > 75.0 {
            effectiveCleanTarget = min(clean, 25.0)
        } else if tension > 60.0 {
            effectiveCleanTarget = min(clean, 50.0)
        } else {
            effectiveCleanTarget = clean
        }

        latestEffectiveCleanPct = asymSmooth(
            old: latestEffectiveCleanPct,
            new: effectiveCleanTarget,
            rise: effectiveCleanRiseSmoothing,
            fall: effectiveCleanFallSmoothing
        )
    }

    func processBrainwave(delta: Double, theta: Double, alpha: Double, beta: Double, gamma: Double) {
        let now = Date()
        let isClean = latestEffectiveCleanPct >= 60.0

        let dt: TimeInterval
        if let last = lastSampleTime {
            dt = now.timeIntervalSince(last)
        } else {
            dt = 0
        }
        lastSampleTime = now

        if isClean {
            switch baselinePhase {
            case .warmup:
                warmupCleanAccum += dt
            case .collecting:
                collectingCleanAccum += dt
            default:
                break
            }
            publishBaselineProgress()
        }

        switch baselinePhase {
        case .idle:
            if isClean {
                baselinePhase = .warmup
                warmupStartTime = now
                warmupCleanAccum = 0
                collectingCleanAccum = 0
                epochs.removeAll()
                recentEpochs.removeAll()
                liveBandSamples.removeAll()
                lastLiveScoringUpdate = nil
                currentState = nil
                scorer.reset()
                lastEpochZDelta = 0
                lastEpochZTheta = 0
                lastEpochZAlpha = 0
                lastEpochZBeta = 0
                lastEpochFAAShift = nil
                latestFAAShift = nil
                latestEffectiveCleanPct = 0
                latestCleanPct = 0
                publishBaselineProgress()
                print("ℹ️ Warm-up started")
            }
        case .warmup:
            if warmupStartTime == nil {
                warmupStartTime = now
            }
            if isClean {
                accumulateEpoch(delta: delta, theta: theta, alpha: alpha, beta: beta, gamma: gamma)
            }
            if warmupCleanAccum >= warmupDuration {
                baselinePhase = .collecting
                collectingCleanAccum = 0
                if epochStartTime == nil { epochStartTime = now }
                publishBaselineProgress()
                print("ℹ️ Collecting baseline epochs...")
                print("⏱️ Warm-up clean time: \(warmupCleanAccum)s")
            }
        case .collecting:
            if epochStartTime == nil { epochStartTime = now }
            if isClean {
                accumulateEpoch(delta: delta, theta: theta, alpha: alpha, beta: beta, gamma: gamma)
            }
            if let eStart = epochStartTime, now.timeIntervalSince(eStart) >= epochDuration {
                closeCollectingEpoch(now: now)
            }
        case .locked:
            guard isClean else { return }
            liveBandSamples.append(
                LiveBandSample(delta: delta, theta: theta, alpha: alpha, beta: beta, gamma: gamma, timestamp: now)
            )
            updateLiveStateScores(now: now)
            accumulateEpoch(delta: delta, theta: theta, alpha: alpha, beta: beta, gamma: gamma)
            if epochStartTime == nil { epochStartTime = now }
            if let eStart = epochStartTime, now.timeIntervalSince(eStart) >= epochDuration {
                closeLockedEpoch(now: now)
            }
        }
    }

    func processFAA(_ faa: Double) {
        let isClean = latestEffectiveCleanPct >= 60.0
        guard isClean else { return }

        if let meanFAA = baselineFAAMean {
            latestFAAShift = faa - meanFAA
        } else {
            latestFAAShift = nil
        }

        switch baselinePhase {
        case .warmup, .collecting, .locked:
            if epochStartTime == nil { epochStartTime = Date() }
            epochSumFAA += faa
            epochFAASampleCount += 1
        default:
            break
        }
    }

    private func accumulateEpoch(delta: Double, theta: Double, alpha: Double, beta: Double, gamma: Double) {
        if epochStartTime == nil { epochStartTime = Date() }
        epochSumDelta += delta
        epochSumTheta += theta
        epochSumAlpha += alpha
        epochSumBeta += beta
        epochSumGamma += gamma
        epochSampleCount += 1
    }

    private func closeCollectingEpoch(now: Date) {
        let n = max(1, epochSampleCount)
        let avgDelta = epochSumDelta / Double(n)
        let avgTheta = epochSumTheta / Double(n)
        let avgAlpha = epochSumAlpha / Double(n)
        let avgBeta = epochSumBeta / Double(n)
        let avgGamma = epochSumGamma / Double(n)
        let (rDelta, rTheta, rAlpha, rBeta, rGamma) = relativeBands(
            delta: avgDelta,
            theta: avgTheta,
            alpha: avgAlpha,
            beta: avgBeta,
            gamma: avgGamma
        )

        let avgFAA: Double? = epochFAASampleCount > 0 ? (epochSumFAA / Double(epochFAASampleCount)) : nil
        let epoch = EpochRel(delta: rDelta, theta: rTheta, alpha: rAlpha, beta: rBeta, gamma: rGamma, faa: avgFAA, timestamp: now)
        epochs.append(epoch)
        print("📦 Epoch added (rel): Δ=\(rounded(rDelta)) Θ=\(rounded(rTheta)) Α=\(rounded(rAlpha)) Β=\(rounded(rBeta)) Γ=\(rounded(rGamma))  (total epochs=\(epochs.count))")

        resetEpoch(now: now)
        lockBaselineIfReady(now: now)
    }

    private func closeLockedEpoch(now: Date) {
        let n = max(1, epochSampleCount)
        let avgDelta = epochSumDelta / Double(n)
        let avgTheta = epochSumTheta / Double(n)
        let avgAlpha = epochSumAlpha / Double(n)
        let avgBeta = epochSumBeta / Double(n)
        let avgGamma = epochSumGamma / Double(n)
        let (rDelta, rTheta, rAlpha, rBeta, rGamma) = relativeBands(
            delta: avgDelta,
            theta: avgTheta,
            alpha: avgAlpha,
            beta: avgBeta,
            gamma: avgGamma
        )

        let avgFAA: Double? = epochFAASampleCount > 0 ? (epochSumFAA / Double(epochFAASampleCount)) : nil
        let zDelta = z(rDelta, mean: baselineMean.delta, std: baselineStd.delta)
        let zTheta = z(rTheta, mean: baselineMean.theta, std: baselineStd.theta)
        let zAlpha = z(rAlpha, mean: baselineMean.alpha, std: baselineStd.alpha)
        let zBeta = z(rBeta, mean: baselineMean.beta, std: baselineStd.beta)
        let zGamma = z(rGamma, mean: baselineMean.gamma, std: baselineStd.gamma)

        appendAndClassifyEpoch(
            zDelta: zDelta,
            zTheta: zTheta,
            zAlpha: zAlpha,
            zBeta: zBeta,
            avgFAA: avgFAA,
            timestamp: now
        )

        let zFAAString: String
        if let meanFAA = baselineFAAMean, let stdFAA = baselineFAAStd, let vFAA = avgFAA {
            let zFAA = (vFAA - meanFAA) / max(stdFAA, 1e-6)
            zFAAString = String(format: " FAA=%.2f", zFAA)
        } else {
            zFAAString = ""
        }

        print("🧠 Z-scores: Θ=\(rounded2(zTheta)) Α=\(rounded2(zAlpha)) Β=\(rounded2(zBeta)) Γ=\(rounded2(zGamma))\(zFAAString)")
        print("📊 Continuous state scores updated from locked epoch")

        resetEpoch(now: now)
    }

    private func resetEpoch(now: Date) {
        epochStartTime = now
        epochSumDelta = 0
        epochSumTheta = 0
        epochSumAlpha = 0
        epochSumBeta = 0
        epochSumGamma = 0
        epochSampleCount = 0
        epochSumFAA = 0
        epochFAASampleCount = 0
    }

    private func publishBaselineProgress() {
        let progress: Double
        switch baselinePhase {
        case .idle:
            progress = 0.0
        case .warmup:
            let stage = max(0.0, min(warmupCleanAccum / max(warmupDuration, 1e-6), 1.0))
            progress = stage * (100.0 / 3.0)
        case .collecting:
            let stage = max(0.0, min(collectingCleanAccum / max(collectingDuration, 1e-6), 1.0))
            progress = (100.0 / 3.0) + (stage * (100.0 / 3.0))
        case .locked:
            progress = 100.0
        }
        delegate?.didReceiveBaselineProgress(progress)
    }

    private func lockBaselineIfReady(now: Date) {
        guard baselinePhase == .collecting else { return }
        guard collectingCleanAccum >= collectingDuration else { return }

        let deltas = epochs.map { $0.delta }
        let thetas = epochs.map { $0.theta }
        let alphas = epochs.map { $0.alpha }
        let betas = epochs.map { $0.beta }
        let gammas = epochs.map { $0.gamma }

        let meanDelta = mean(of: deltas)
        let meanTheta = mean(of: thetas)
        let meanAlpha = mean(of: alphas)
        let meanBeta = mean(of: betas)
        let meanGamma = mean(of: gammas)
        baselineMean = (meanDelta, meanTheta, meanAlpha, meanBeta, meanGamma)
        baselineStd = (
            stddev(of: deltas),
            stddev(of: thetas),
            stddev(of: alphas),
            stddev(of: betas),
            stddev(of: gammas)
        )

        let faaVals = epochs.compactMap { $0.faa }
        if faaVals.count >= 3 {
            let meanFAA = mean(of: faaVals)
            let stdFAA = stddev(of: faaVals)
            baselineFAAMean = meanFAA
            baselineFAAStd = stdFAA
            print("📐 FAA baseline locked: mean=\(meanFAA), std=\(stdFAA)")
        } else {
            baselineFAAMean = nil
            baselineFAAStd = nil
            latestFAAShift = nil
        }

        baselinePhase = .locked
        publishBaselineProgress()
        print("⏱️ Collecting clean time reached: \(collectingCleanAccum)s")
        print("✅ Baseline locked: mean Δ=\(meanDelta), Θ=\(meanTheta), Α=\(meanAlpha), Β=\(meanBeta), Γ=\(meanGamma); std Δ=\(baselineStd.delta), Θ=\(baselineStd.theta), Α=\(baselineStd.alpha), Β=\(baselineStd.beta), Γ=\(baselineStd.gamma)")
    }

    private func appendAndClassifyEpoch(
        zDelta: Double,
        zTheta: Double,
        zAlpha: Double,
        zBeta: Double,
        avgFAA: Double?,
        timestamp: Date
    ) {
        let faaShift: Double?
        if let meanFAA = baselineFAAMean, let value = avgFAA {
            faaShift = value - meanFAA
        } else {
            faaShift = nil
        }

        let epoch = EpochZ(
            zDelta: zDelta,
            zTheta: zTheta,
            zAlpha: zAlpha,
            zBeta: zBeta,
            faaShift: faaShift,
            timestamp: timestamp
        )
        recentEpochs.append(epoch)
        if recentEpochs.count > maxRecentEpochs {
            recentEpochs.removeFirst(recentEpochs.count - maxRecentEpochs)
        }

        classifyRecentEpochs()
    }

    private func classifyRecentEpochs() {
        guard recentEpochs.count >= 2 else { return }

        let last2 = Array(recentEpochs.suffix(2))
        let avgDelta2 = mean(of: last2.map { $0.zDelta })
        let avgTheta2 = mean(of: last2.map { $0.zTheta })
        let avgAlpha2 = mean(of: last2.map { $0.zAlpha })
        let avgBeta2 = mean(of: last2.map { $0.zBeta })
        let avgFAA2 = last2.compactMap { $0.faaShift }
        let avgFAAshift2 = avgFAA2.isEmpty ? nil : mean(of: avgFAA2)

        lastEpochZDelta = avgDelta2
        lastEpochZTheta = avgTheta2
        lastEpochZAlpha = avgAlpha2
        lastEpochZBeta = avgBeta2
        lastEpochFAAShift = avgFAAshift2

        let scores = scorer.applyStateScores(
            zDelta: avgDelta2,
            zTheta: avgTheta2,
            zAlpha: avgAlpha2,
            zBeta: avgBeta2,
            smoothing: 0.35
        )
        delegate?.didReceiveBrainwaveState(meditation: scores.meditation, focus: scores.focus, dreamy: scores.dreamy)

        let states: [(String, Double)] = [
            ("Meditative Absorption", scores.meditation),
            ("Dreamy", scores.dreamy),
            ("Focused Cognitive Engagement", scores.focus)
        ]

        if let strongest = states.max(by: { $0.1 < $1.1 }), strongest.1 >= 55.0 {
            let faaString = avgFAAshift2 != nil ? String(format: "%.2f", avgFAAshift2!) : "n/a"
            logStateIfChanged(
                strongest.0,
                details: "meditation=\(rounded2(scores.meditation)) focus=\(rounded2(scores.focus)) dreamy=\(rounded2(scores.dreamy)) Δz=\(rounded2(avgDelta2)) θz=\(rounded2(avgTheta2)) αz=\(rounded2(avgAlpha2)) βz=\(rounded2(avgBeta2)) FAAΔ=\(faaString)"
            )
        }
    }

    private func updateLiveStateScores(now: Date) {
        guard baselinePhase == .locked else { return }

        if let lastUpdate = lastLiveScoringUpdate,
           now.timeIntervalSince(lastUpdate) < liveScoringInterval {
            return
        }

        let cutoff = now.addingTimeInterval(-liveScoringWindow)
        liveBandSamples.removeAll { $0.timestamp < cutoff }
        guard !liveBandSamples.isEmpty else {
            lastLiveScoringUpdate = now
            return
        }

        let avgDelta = mean(of: liveBandSamples.map { $0.delta })
        let avgTheta = mean(of: liveBandSamples.map { $0.theta })
        let avgAlpha = mean(of: liveBandSamples.map { $0.alpha })
        let avgBeta = mean(of: liveBandSamples.map { $0.beta })
        let avgGamma = mean(of: liveBandSamples.map { $0.gamma })
        let (rDelta, rTheta, rAlpha, rBeta, _) = relativeBands(
            delta: avgDelta,
            theta: avgTheta,
            alpha: avgAlpha,
            beta: avgBeta,
            gamma: avgGamma
        )

        let liveZDelta = z(rDelta, mean: baselineMean.delta, std: baselineStd.delta)
        let liveZTheta = z(rTheta, mean: baselineMean.theta, std: baselineStd.theta)
        let liveZAlpha = z(rAlpha, mean: baselineMean.alpha, std: baselineStd.alpha)
        let liveZBeta = z(rBeta, mean: baselineMean.beta, std: baselineStd.beta)

        let zDelta = (0.7 * liveZDelta) + (0.3 * lastEpochZDelta)
        let zTheta = (0.7 * liveZTheta) + (0.3 * lastEpochZTheta)
        let zAlpha = (0.7 * liveZAlpha) + (0.3 * lastEpochZAlpha)
        let zBeta = (0.7 * liveZBeta) + (0.3 * lastEpochZBeta)

        let scores = scorer.applyStateScores(
            zDelta: zDelta,
            zTheta: zTheta,
            zAlpha: zAlpha,
            zBeta: zBeta,
            smoothing: 0.18
        )
        delegate?.didReceiveBrainwaveState(meditation: scores.meditation, focus: scores.focus, dreamy: scores.dreamy)

        lastLiveScoringUpdate = now
    }

    private func relativeBands(delta: Double, theta: Double, alpha: Double, beta: Double, gamma: Double) -> (Double, Double, Double, Double, Double) {
        let total = max(1e-9, delta + theta + alpha + beta + gamma)
        return (delta / total, theta / total, alpha / total, beta / total, gamma / total)
    }

    private func mean(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func stddev(of values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let meanValue = mean(of: values)
        let variance = values.reduce(0) { $0 + pow($1 - meanValue, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }

    private func asymSmooth(old: Double, new: Double, rise: Double, fall: Double) -> Double {
        let factor = new > old ? clamp01(rise) : clamp01(fall)
        return (factor * new) + ((1.0 - factor) * old)
    }

    private func z(_ value: Double, mean: Double, std: Double) -> Double {
        (value - mean) / max(std, 1e-6)
    }

    private func clamp01(_ x: Double) -> Double {
        max(0.0, min(1.0, x))
    }

    private func logStateIfChanged(_ state: String, details: String) {
        if currentState != state {
            currentState = state
            print("🏷️ State: \(state) — \(details)")
        } else {
            print("… \(state) continuing — \(details)")
        }
    }

    private func rounded(_ x: Double) -> String {
        String(format: "%.3f", x)
    }

    private func rounded2(_ x: Double) -> String {
        String(format: "%.2f", x)
    }
}
