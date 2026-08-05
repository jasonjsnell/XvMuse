//
//  EEGStateAnalyzer.swift
//  XvMuse
//

import Foundation

protocol EEGStateAnalyzerDelegate: AnyObject {
    func didReceiveBrainwaveState(meditation: Double, focus: Double, dreamy: Double)
    func didReceiveBrainwaveDimensions(
        tiltHz: Double,
        steadiness: Double,
        intensity: Double,
        spreadHz: Double,
        confidence: Double,
        alphaPaceHz: Double
    )
}

/* Measures brainwave states from the live spectrum.

 FLOW
   detail spectrum (already band-passed before the FFT, forehead sensors only)
     -> undo the filter's own frequency response
     -> reduce to centroid, spread, and total power
     -> combine with artifact-screened band balance
     -> publish focus / meditation / dreamy.

Scores publish immediately from live measurements. */

final class EEGStateAnalyzer {

    weak var delegate: EEGStateAnalyzerDelegate?

    //MARK: - Tunables

    //signal must be at least this clean before anything is measured
    private let cleanThreshold: Double = 60.0

    //how often scores are published, and how hard they are smoothed
    private let publishInterval: TimeInterval = 0.25
    private let scoreSmoothing: Double = 0.18
    private let blockedFadeSmoothing: Double = 0.05

    //how far back the "is the centroid parked or wandering" judgement looks
    private let stabilityWindow: TimeInterval = 8.0

    //detail-window power range used for the 0...1 intensity dimension
    private let intensityLowLogPower: Double = 0.0
    private let intensityHighLogPower: Double = 3.0

    //ignore bins the filter has pushed below half amplitude; correcting them amplifies noise
    private let minimumFilterResponse: Double = 0.5

    //MARK: - Diagnostics

    //set false to silence the per-second state log
    private let logStates: Bool = true
    private let logInterval: TimeInterval = 1.0
    private var lastLogTime: Date? = nil
    private let launchTime = Date()

    //MARK: - Signal quality

    private var latestCleanPct: Double = 0.0
    private var latestEffectiveCleanPct: Double = 0.0
    private var latestTensionPct: Double = 0.0
    private var latestBlinkPct: Double = 0.0
    private let effectiveCleanRiseSmoothing: Double = 0.35
    private let effectiveCleanFallSmoothing: Double = 0.12

    //blink above this cuts the clean gate instantly rather than easing down through the smoother
    private let blinkHardBlockPct: Double = 60.0

    //band levels in dB, delayed slightly so blink/tension artifacts can invalidate pre-roll frames
    private var latestBands: BandBalance? = nil
    private struct TimedBands {
        var bands: BandBalance
        let timestamp: Date
        var contaminated: Bool
    }
    private var pendingBands: [TimedBands] = []
    private let bandArtifactPreRollWindow: TimeInterval = 0.75
    private let bandArtifactDelay: TimeInterval = 0.75
    private let bandHistoryWindow: TimeInterval = 2.0
    private var smoothedQuiet: Double = 0.0
    private let quietRiseSmoothing: Double = 0.12
    private let quietFallSmoothing: Double = 0.45

    //MARK: - Detail window mapping

    private let usableBins: [Int]       //spectrum indices inside the trusted part of the band
    private let usableFreqs: [Double]   //centre frequency of each, in Hz
    private let compensation: [Double]  //1 / |H(f)|^2, undoes the band-pass filter's own shape
    private let binWidthHz: Double

    /* What this window reads for a featureless 1/f spectrum. Derived in init; the scorer treats
     every centroid/spread threshold as an offset from these. */
    private let nullCentroidHz: Double
    private let nullSpreadHz: Double
    //MARK: - Stability

    private var recentCentroids: [(value: Double, timestamp: Date)] = []
    private var lastPublish: Date? = nil
    private let scorer = EEGStateScorer()
    private var lastTiltHz: Double = 0.0
    private var lastSteadiness: Double = 0.0
    private var lastIntensity: Double = 0.0
    private var lastSpreadHz: Double = 0.0
    private var lastConfidence: Double = 0.0
    private var lastAlphaPaceHz: Double = 0.0

    //MARK: - Alpha pace tracking
    private var smoothedAlphaPaceHz: Double = 0.0
    private var alphaPaceSampleCount: Int = 0

    //peak must clear the band's own average by this much before it counts as a rhythm
    private let alphaPaceMinProminenceDb: Double = 3.0

    //~2 minutes at the 4 Hz publish rate
    private let alphaPaceSmoothing: Double = 0.002

    //MARK: - Init

    init(
        sampleRate: Double = MuseConstants.SAMPLING_RATE,
        fftBins: Int = MuseConstants.EEG_FFT_BINS,
        lowHz: Double = MuseConstants.DETAIL_BANDPASS_LOW_HZ,
        highHz: Double = MuseConstants.DETAIL_BANDPASS_HIGH_HZ
    ) {
        binWidthHz = sampleRate / Double(fftBins)

        /* Rebuild the same filter the detail spectrum was produced with, purely to read back its
         frequency response. The filter ramps rather than cuts, so bins near the edges of the band
         arrive quieter than the brain actually was there. */
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
            bins.removeAll()
            freqs.removeAll()
            comp.removeAll()

            for bin in 0..<(fftBins / 2) {
                let hz = Double(bin) * binWidthHz
                guard hz >= lowHz, hz <= highHz else { continue }
                bins.append(bin)
                freqs.append(hz)
                comp.append(1.0)
            }

            print("EEGStateAnalyzer: filter response too soft to compensate, measuring band flat")
        }

        usableBins = bins
        usableFreqs = freqs
        compensation = comp

        /* THE WINDOW'S OWN NULL.

         What centroid and spread read for a spectrum with no structure in it at all — just the 1/f
         background, power falling as f^-2. This is the reading a dead-flat brain produces, and
         every centroid/spread threshold in the scorer is expressed as an offset from it.

         Computed from the surviving bins rather than from lowHz/highHz analytically, so it tracks
         whatever the filter-response cut actually left behind. Widening the window from 10-20 to
         8-20 moves this from 13.86 Hz to about 12.22 Hz; because the thresholds are offsets, the
         scorer re-tunes itself and nothing downstream needs touching. */
        var weight = 0.0
        var weightedFreq = 0.0
        for hz in freqs {
            let power = pow(max(hz, 1e-6), -2.0)
            weight += power
            weightedFreq += power * hz
        }

        var nullCentroid = 0.0
        var nullSpread = 0.0
        if weight > 1e-12 {
            nullCentroid = weightedFreq / weight
            var variance = 0.0
            for hz in freqs {
                let power = pow(max(hz, 1e-6), -2.0)
                let offset = hz - nullCentroid
                variance += power * offset * offset
            }
            nullSpread = (variance / weight).squareRoot()
        }

        nullCentroidHz = nullCentroid
        nullSpreadHz = nullSpread

        if nullCentroid.isFinite, nullSpread.isFinite, nullSpread > 0 {
            scorer.configureWindow(nullCentroidHz: nullCentroid, nullSpreadHz: nullSpread)
        }

        print(String(
            format: "EEGStateAnalyzer: detail window %.1f-%.1f Hz, %d usable bins, 1/f null centroid %.2f Hz spread %.2f Hz",
            lowHz, highHz, bins.count, nullCentroid, nullSpread
        ))
    }

    //MARK: - Input

    func updateSignalQuality(clean: Double, tension: Double, blink: Double) {

        let now = Date()

        latestCleanPct = clean
        latestTensionPct = tension
        latestBlinkPct = blink

        if bandArtifactIsActive {
            markRecentBandsContaminated(now: now)
        }

        /* Muscle tension makes the spectrum look busier than the brain actually is, so it caps
         how clean the signal is allowed to count as rather than being handled separately. */
        var target = clean
        if tension > 75.0 {
            target = min(target, 25.0)
        } else if tension > 60.0 {
            target = min(target, 50.0)
        }

        //Blinks are brief artifacts; during one, the clean-state dimensions should fade, not freeze.
        if blink > 75.0 {
            target = min(target, 25.0)
        } else if blink > 50.0 {
            target = min(target, 50.0)
        }

        latestEffectiveCleanPct = asymSmooth(
            old: latestEffectiveCleanPct,
            new: target,
            rise: effectiveCleanRiseSmoothing,
            fall: effectiveCleanFallSmoothing
        )

        /* A blink has to cut through instantly, not ease down.

         Falling at 0.12 per update takes about eight frames to get from 100 down under the clean
         threshold, and a blink is over in one or two — so blinks were leaking straight past the
         gate. In the coding recording that showed up as centroid crashing to 9.5 Hz with logPower
         spiking near 3.0, and stability sitting at 0.00 through every blink-heavy stretch.

         Recovery still uses the normal rise smoothing, so this cuts sharply and returns gently. */
        if blink > blinkHardBlockPct {
            latestEffectiveCleanPct = min(latestEffectiveCleanPct, 20.0)
        }
    }

    /* Band levels in dB. Call before processDetailSpectrum; the stored values are delayed briefly
     before scoring so a blink/tension detection can also invalidate the readings right before it. */
    func updateBands(
        delta: Double,
        theta: Double,
        alpha: Double,
        beta: Double,
        gamma: Double,
        quiet: Double
    ) {
        /* Quiet is fed through a smoother before it reaches the scorer. The raw value is close to
         bimodal — it swings between 0 and 100 from one reading to the next, because the absolute
         scale it maps through saturates at both ends. Used raw as a gate it made dreamy flicker
         on and off every second regardless of what the brain was doing. */
        if !smoothedQuiet.isFinite {
            smoothedQuiet = 0.0
        }
        let safeQuiet = quiet.isFinite ? max(0.0, min(100.0, quiet)) : 0.0
        let quietSmoothing = safeQuiet < smoothedQuiet ? quietFallSmoothing : quietRiseSmoothing
        smoothedQuiet += quietSmoothing * (safeQuiet - smoothedQuiet)

        let now = Date()
        let bands = BandBalance(
            delta: delta,
            theta: theta,
            alpha: alpha,
            beta: beta,
            gamma: gamma,
            quiet: smoothedQuiet
        )

        pendingBands.append(TimedBands(
            bands: bands,
            timestamp: now,
            contaminated: bandArtifactIsActive
        ))

        if bandArtifactIsActive {
            markRecentBandsContaminated(now: now)
        }

        prunePendingBands(now: now)
        latestBands = latestArtifactScreenedBands(now: now)
    }

    func processDetailSpectrum(_ spectrum: [Double]) {

        guard !spectrum.isEmpty, !usableBins.isEmpty else { return }

        let now = Date()

        guard !noiseBlocksCleanData else {
            publishBlockedFadeIfDue(now: now)
            return
        }

        guard let features = measure(spectrum, at: now) else {
            publishBlockedFadeIfDue(now: now)
            return
        }

        guard !cleanShapeIsBlocked else {
            publishBlockedFadeIfDue(
                now: now,
                liveTiltHz: features.centroidHz,
                liveIntensity: intensity(from: features),
                liveSpreadHz: features.spreadHz,
                liveAlphaPaceHz: features.alphaPaceHz,
                fadeFocus: shouldFadeFocusDuringCleanBlock
            )
            return
        }

        trackStability(features, now: now)
        publishIfDue(features, now: now)
    }

    func reset() {
        recentCentroids.removeAll()
        lastPublish = nil
        lastLogTime = nil
        latestCleanPct = 0
        latestEffectiveCleanPct = 0
        latestTensionPct = 0
        latestBlinkPct = 0
        latestBands = nil
        pendingBands.removeAll()
        smoothedQuiet = 0
        lastTiltHz = 0
        lastSteadiness = 0
        lastIntensity = 0
        lastSpreadHz = 0
        lastConfidence = 0
        lastAlphaPaceHz = 0
        //each test set is a different person-session; identity must not carry over
        smoothedAlphaPaceHz = 0
        alphaPaceSampleCount = 0
        scorer.reset()
    }

    //MARK: - Measurement

    /* Reduce one spectrum to independent measurements. Filter compensation happens here, so
     everything downstream is working with the estimated unshaped spectrum. */
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

        return DetailFeatures(
            centroidHz: centroid,
            spreadHz: spread,
            logPower: log10(total + 1e-12),
            alphaPaceHz: alphaPaceHz(fromDetailSpectrum: spectrum) ?? lastAlphaPaceHz,
            timestamp: now
        )
    }

    /* Which frequency this person's alpha rhythm runs at.

     IDENTITY, NOT CONTROL. It barely moves within a session and cannot be changed deliberately,
     so it is tracked over minutes and only accepted from frames where a peak genuinely exists.

     Three guards, all of which were missing and all of which mattered. Without them this reported
     the raw argmax bin every frame: integers only, jumping the full 8-13 Hz range frame to frame
     and repeatedly landing on both boundaries. A uniform spread across the search range is the
     signature of tracking noise, not of a rhythm — a flat band still has a maximum bin.

       1. PROMINENCE. Require the peak to stand clear of the band's own average before believing
          it at all. Measured on the detrended residual, so the 1/f slope cannot supply the peak.
       2. SUB-BIN INTERPOLATION. Bins are 1 Hz apart and 10 vs 11 Hz is a real personal difference,
          so a parabola through the peak and its neighbours recovers the true maximum between bin
          centres. This is also why the value stops being an integer.
       3. SLOW TRACKING. An EWMA over roughly two minutes, seeded on the first accepted frame.
          Identity should settle, not chase.

     Returns nil when this frame has nothing worth accepting; the caller holds the last value. */
    private func alphaPaceHz(fromDetailSpectrum spectrum: [Double]) -> Double? {
        guard !spectrum.isEmpty else { return nil }

        let alphaLowHz = 7.0
        let alphaHighHz = 13.0
        let points = usableBins.enumerated().compactMap { index, bin -> (hz: Double, power: Double)? in
            guard bin < spectrum.count else { return nil }
            let hz = usableFreqs[index]
            guard hz >= alphaLowHz, hz <= alphaHighHz else { return nil }
            let power = max(0.0, spectrum[bin]) * compensation[index]
            guard power > 1e-12 else { return nil }
            return (hz: hz, power: power)
        }

        let flattened = flattenedDbValues(points)
        guard flattened.count >= 3 else { return nil }

        var peakIndex = 0
        for (i, point) in flattened.enumerated() where point.db > flattened[peakIndex].db {
            peakIndex = i
        }

        //1. is it actually a peak? least squares puts the mean residual at 0, so this is the excess
        guard flattened[peakIndex].db >= alphaPaceMinProminenceDb else { return nil }

        //2. sub-bin location
        var estimateHz = flattened[peakIndex].hz
        if peakIndex > 0, peakIndex < flattened.count - 1 {
            let a = flattened[peakIndex - 1].db
            let b = flattened[peakIndex].db
            let c = flattened[peakIndex + 1].db
            let denominator = a - (2.0 * b) + c
            if abs(denominator) > 1e-9 {
                let offset = max(-0.5, min(0.5, 0.5 * (a - c) / denominator))
                estimateHz += offset * binWidthHz
            }
        }

        guard estimateHz.isFinite else { return nil }

        //3. settle rather than chase
        if alphaPaceSampleCount == 0 {
            smoothedAlphaPaceHz = estimateHz
        } else {
            smoothedAlphaPaceHz += alphaPaceSmoothing * (estimateHz - smoothedAlphaPaceHz)
        }
        alphaPaceSampleCount += 1

        return smoothedAlphaPaceHz
    }

    private func flattenedDbValues(_ points: [(hz: Double, power: Double)]) -> [(hz: Double, db: Double)] {
        guard points.count >= 3 else { return [] }

        let samples = points.map { point -> (hz: Double, x: Double, y: Double) in
            let hz = max(point.hz, 1e-6)
            let power = max(point.power, 1e-12)
            return (hz: point.hz, x: log10(hz), y: 10.0 * log10(power))
        }

        let count = Double(samples.count)
        let sumX = samples.reduce(0.0) { $0 + $1.x }
        let sumY = samples.reduce(0.0) { $0 + $1.y }
        let sumXX = samples.reduce(0.0) { $0 + ($1.x * $1.x) }
        let sumXY = samples.reduce(0.0) { $0 + ($1.x * $1.y) }
        let denominator = (count * sumXX) - (sumX * sumX)

        guard abs(denominator) > 1e-12 else {
            return samples.map { (hz: $0.hz, db: $0.y) }
        }

        let slope = ((count * sumXY) - (sumX * sumY)) / denominator
        let intercept = (sumY - (slope * sumX)) / count

        return samples.map { sample in
            let trend = intercept + (slope * sample.x)
            return (hz: sample.hz, db: sample.y - trend)
        }
    }

    //MARK: - Stability

    private func trackStability(_ features: DetailFeatures, now: Date) {
        recentCentroids.append((features.centroidHz, now))
        pruneRecentCentroids(now: now)
    }

    private func pruneRecentCentroids(now: Date) {
        let cutoff = now.addingTimeInterval(-stabilityWindow)
        recentCentroids.removeAll { $0.timestamp < cutoff }
    }

    /* How still the centroid has been holding, 0 (wandering) to 1 (parked), judged by absolute
     Hz movement over the recent window. */
    private var centroidStability: Double {

        guard recentCentroids.count >= 4 else { return 0.5 }

        let values = recentCentroids.map { $0.value }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let recentSD = sqrt(variance)

        return invRamp(recentSD, low: 0.25, high: 1.6)
    }

    //MARK: - Output

    private func publishIfDue(_ features: DetailFeatures, now: Date) {

        if let last = lastPublish, now.timeIntervalSince(last) < publishInterval { return }
        lastPublish = now

        let steadiness = centroidStability
        let intensity = intensity(from: features)

        let scores = scorer.applyStateScores(
            centroidHz: features.centroidHz,
            spreadHz: features.spreadHz,
            logPower: features.logPower,
            stability: steadiness,
            bands: latestBands,
            tension: latestTensionPct,
            smoothing: scoreSmoothing
        )

        lastTiltHz = features.centroidHz
        lastSteadiness = steadiness
        lastIntensity = intensity
        lastSpreadHz = features.spreadHz
        lastConfidence = cleanConfidence01
        lastAlphaPaceHz = features.alphaPaceHz

        delegate?.didReceiveBrainwaveState(
            meditation: scores.meditation,
            focus: scores.focus,
            dreamy: scores.dreamy
        )

        delegate?.didReceiveBrainwaveDimensions(
            tiltHz: features.centroidHz,
            steadiness: steadiness,
            intensity: intensity,
            spreadHz: features.spreadHz,
            confidence: lastConfidence,
            alphaPaceHz: features.alphaPaceHz
        )

        logState(features: features, scores: scores, now: now)
    }

    private func publishBlockedFadeIfDue(
        now: Date,
        liveTiltHz: Double? = nil,
        liveIntensity: Double? = nil,
        liveSpreadHz: Double? = nil,
        liveAlphaPaceHz: Double? = nil,
        fadeFocus: Bool = true
    ) {

        if let last = lastPublish, now.timeIntervalSince(last) < publishInterval { return }
        lastPublish = now

        let scores = scorer.fadeScores(factor: blockedFadeSmoothing, fadeFocus: fadeFocus)
        if let liveTiltHz {
            lastTiltHz = liveTiltHz
        }
        if let liveIntensity {
            lastIntensity = liveIntensity
        }
        if let liveSpreadHz {
            lastSpreadHz = liveSpreadHz
        }
        if let liveAlphaPaceHz {
            lastAlphaPaceHz = liveAlphaPaceHz
        }
        lastConfidence = cleanConfidence01

        pruneRecentCentroids(now: now)

        delegate?.didReceiveBrainwaveState(
            meditation: scores.meditation,
            focus: scores.focus,
            dreamy: scores.dreamy
        )

        delegate?.didReceiveBrainwaveDimensions(
            tiltHz: lastTiltHz,
            steadiness: lastSteadiness,
            intensity: lastIntensity,
            spreadHz: lastSpreadHz,
            confidence: lastConfidence,
            alphaPaceHz: lastAlphaPaceHz
        )

        // STATE BLOCKED logs are intentionally muted during live state tuning.
    }

    /* Per-second diagnostic dump. Prints the inputs to every score alongside the scores, because
     a score on its own only says something is wrong, never why. */
    private func logState(
        features: DetailFeatures,
        scores: (meditation: Double, focus: Double, dreamy: Double),
        now: Date
    ) {
        guard logStates else { return }
        if let last = lastLogTime, now.timeIntervalSince(last) < logInterval { return }
        lastLogTime = now

        let elapsed = now.timeIntervalSince(launchTime)

        print(String(
            format: "STATE SCORE | t:%6.1f | focus:%3.0f meditation:%3.0f dreamy:%3.0f | clean:%3.0f effClean:%3.0f tension:%3.0f blink:%3.0f conf:%4.2f",
            elapsed,
            scores.focus, scores.meditation, scores.dreamy,
            latestCleanPct,
            latestEffectiveCleanPct,
            latestTensionPct,
            latestBlinkPct,
            lastConfidence
        ))

        let loggedQuiet: Double = latestBands?.quiet ?? -1.0
        print(String(
            format: "STATE INPUTS | t:%6.1f | tilt:%5.2fHz (%+5.2f vs null %5.2f) spread:%5.2fHz (%+5.2f) alphaPace:%5.2fHz power:%5.2f steadiness:%4.2f quiet:%3.0f",
            elapsed,
            features.centroidHz,
            features.centroidHz - nullCentroidHz,
            nullCentroidHz,
            features.spreadHz,
            features.spreadHz - nullSpreadHz,
            features.alphaPaceHz,
            features.logPower,
            centroidStability,
            loggedQuiet
        ))

        print(String(
            format: "FOCUS INPUTS | t:%6.1f | gate:%4.2f fast:%4.2f calm:%4.2f notAlpha:%4.2f broad:%4.2f steady:%4.2f support:%4.2f",
            elapsed,
            scorer.focusGate,
            scorer.focusFastCentroid,
            scorer.focusCalmCentroid,
            scorer.focusNotAlphaLed,
            scorer.focusBroadEnough,
            scorer.focusHoldingSteady,
            scorer.focusSupport
        ))

        print(String(
            format: "MEDITATION INPUTS | t:%6.1f | alphaLead(detrend):%+5.1fdB gate:%4.2f alphaCentroid:%4.2f organized:%4.2f steady:%4.2f support:%4.2f awake:%4.2f",
            elapsed,
            scorer.meditationAlphaLeadDb,
            scorer.medGate,
            scorer.meditationAlphaCentroid,
            scorer.meditationOrganized,
            scorer.meditationHoldingSteady,
            scorer.medSupport,
            scorer.meditationAwakeEnough
        ))

        if let bands = latestBands {
            print(String(
                format: "DREAMY INPUTS | t:%6.1f | raw D:%5.1f T:%5.1f A:%5.1f B:%5.1f G:%5.1f | resid D:%+5.1f T:%+5.1f A:%+5.1f B:%+5.1f | thetaLead:%+5.1f sm:%+5.1f gate:%4.2f | thetaFast:%+5.1f gate:%4.2f | quiet:%3.0f (unused:%4.2f) | thetaDelta:%+5.1f gate:%4.2f | notFast:%4.2f | tensionDamp:%4.2f",
                elapsed,
                bands.delta, bands.theta, bands.alpha, bands.beta, bands.gamma,
                bands.deltaResidual, bands.thetaResidual, bands.alphaResidual, bands.betaResidual,
                scorer.dreamyThetaLeadDb,
                scorer.dreamySmoothedThetaLeadDb,
                scorer.dreamyGate,
                scorer.dreamyThetaVsFastDb,
                scorer.dreamyClearOfFastBands,
                bands.quiet,
                scorer.dreamyStillnessPresent,
                scorer.dreamyThetaVsDeltaDb,
                scorer.dreamyCalmLowEnd,
                scorer.dreamyNotRunningFast,
                RelaxedStateGate.damping(forTension: latestTensionPct)
            ))
        }
    }

    //MARK: - Helpers

    private func asymSmooth(old: Double, new: Double, rise: Double, fall: Double) -> Double {
        let factor = new > old ? clamp01(rise) : clamp01(fall)
        return (factor * new) + ((1.0 - factor) * old)
    }

    private var noiseBlocksCleanData: Bool {
        latestCleanPct < cleanThreshold
    }

    private var cleanShapeIsBlocked: Bool {
        latestEffectiveCleanPct < cleanThreshold ||
        latestTensionPct > 60.0 ||
        latestBlinkPct > 50.0
    }

    private var bandArtifactIsActive: Bool {
        latestTensionPct > 60.0 ||
        latestBlinkPct > 50.0
    }

    private func markRecentBandsContaminated(now: Date) {
        let cutoff = now.addingTimeInterval(-bandArtifactPreRollWindow)
        for index in pendingBands.indices {
            if pendingBands[index].timestamp >= cutoff {
                pendingBands[index].contaminated = true
            }
        }
    }

    private func prunePendingBands(now: Date) {
        let cutoff = now.addingTimeInterval(-bandHistoryWindow)
        pendingBands.removeAll { $0.timestamp < cutoff }
    }

    private func latestArtifactScreenedBands(now: Date) -> BandBalance? {
        let matureCutoff = now.addingTimeInterval(-bandArtifactDelay)
        return pendingBands.last {
            $0.timestamp <= matureCutoff && !$0.contaminated
        }?.bands
    }

    private var shouldFadeFocusDuringCleanBlock: Bool {
        latestTensionPct > 60.0
    }

    private func intensity(from features: DetailFeatures) -> Double {
        ramp(features.logPower, low: intensityLowLogPower, high: intensityHighLogPower)
    }

    private var cleanConfidence01: Double {
        ramp(latestEffectiveCleanPct, low: cleanThreshold, high: 95.0)
    }

    private func clamp01(_ x: Double) -> Double {
        max(0.0, min(1.0, x))
    }

    private func ramp(_ x: Double, low: Double, high: Double) -> Double {
        guard high > low else { return x >= high ? 1.0 : 0.0 }
        return clamp01((x - low) / (high - low))
    }

    private func invRamp(_ x: Double, low: Double, high: Double) -> Double {
        1.0 - ramp(x, low: low, high: high)
    }
}
