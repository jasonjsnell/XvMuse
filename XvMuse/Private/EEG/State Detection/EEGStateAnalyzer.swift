//
//  EEGStateAnalyzer.swift
//  XvMuse
//

import Foundation
import XvEEG //for the quiet calibration anchors printed alongside the raw dB in logState

protocol EEGStateAnalyzerDelegate: AnyObject {
    func didReceiveBrainwaveState(meditation: Double, focus: Double, dreamy: Double)
    func didReceiveBrainwaveDimensions(
        tiltHz: Double,
        steadiness: Double,
        intensity: Double,
        spreadHz: Double,
        confidence: Double,
        rhythmHz: Double,
        rhythmSlowHz: Double
    )
    //live per-term breakdown + gate values for the tuning panel, at the publish cadence
    func didReceiveStateTuningReadout(_ readout: [String: Double])
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

    //signal must be at least this clean before anything is measured (runtime-tunable)
    private var cleanThreshold: Double = 60.0

    //how often scores are published, and how hard they are smoothed
    private let publishInterval: TimeInterval = 0.25
    private var scoreSmoothing: Double = 0.18
    private var blockedFadeSmoothing: Double = 0.05

    //centroid-SD (Hz) bounds for the steadiness ramp (runtime-tunable)
    private var stabilityLowSD: Double = 0.25
    private var stabilityHighSD: Double = 1.6

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

    /* Detail is the per-second dump for each state; the summaries are one line per state per
     window with the distribution. For a labeled calibration run (the pre-recorded Muse 2 state
     sets) set logStateDetail to false — a handful of summary lines describe a session better
     than 500 instantaneous ones, and can actually be pasted. */
    private let logStateDetail: Bool = true
    ///FOCUS-ONLY MODE. Set true to bring the meditation and dreamy dumps back.
    private let logMeditationAndDreamy: Bool = false
    private let stateSummaryInterval: TimeInterval = 10.0
    private var stateSummaryStart: Date? = nil
    private var dreamySamples: [DreamySample] = []
    private var focusSamples: [FocusSample] = []
    private var medSamples: [MedSample] = []
    private var dreamyRejectedFrames: Int = 0

    private struct DreamySample {
        let score: Double
        let smoothedLead: Double
        let leadGate: Double
        let vsFast: Double
        let notFast: Double
        let rhythm: Double
        let calmGamma: Double
        let lowEnd: Double
        let limitName: String
        let tension: Double
        let blink: Double
        let clean: Double
    }

    private struct FocusSample {
        let score: Double
        let shape: Double
        let fast: Double
        let calm: Double
        let notAlphaLed: Double
        let broad: Double
        let steady: Double
        let support: Double
        let limitName: String
        //raw measurements — the summary reports their percentiles, which is what a new
        //threshold is actually read off
        let tiltHz: Double
        let spreadHz: Double
        let alphaLeadDb: Double
    }

    private struct MedSample {
        let score: Double
        let alphaLeadDb: Double
        let alphaLeads: Double
        let centroid: Double
        let organized: Double
        let steady: Double
        let support: Double
        let limitName: String
    }
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
    private var lastRhythmHz: Double = 0.0
    private var lastRhythmSlowHz: Double = 0.0

    //MARK: - Dominant rhythm tracking

    private var fastDominantHz: Double = 0.0
    private var slowDominantHz: Double = 0.0
    private var dominantSampleCount: Int = 0
    private var lastDominantUpdate: Date? = nil
    //accepted estimates held during warm-up so slow seeds from their median, not from sample one
    private var dominantWarmup: [Double] = []
    private var dominantWarmupStart: Date? = nil
    private var dominantWarmupComplete: Bool = false

    //full-spectrum search span. 5 Hz reaches drowsy theta; 20 matches the detail window's top.
    /* Theta prominence: fit the background across 2-12 Hz, find the peak inside 4-7 Hz. The fit
     window has to be wide enough that a narrow bump cannot drag the line it is being measured
     against, and the peak window is the theta band itself. */
    private let thetaShapeLowHz: Double = 2.0
    private let thetaShapeHighHz: Double = 12.0
    private let thetaPeakLowHz: Double = 4.0
    private let thetaPeakHighHz: Double = 7.0

    private let dominantLowHz: Double = 5.0
    private let dominantHighHz: Double = 20.0
    private var dominantBins: [Int] = []
    private var dominantFreqs: [Double] = []

    /* THETA PROMINENCE — DIAGNOSTIC ONLY, scores nothing yet.

     Dreamy currently asks how LOUD theta is relative to a fitted background. Measured on a
     loose-fit Muse S session, that question has a bad answer: against a well-seated session on the
     same headset, theta rose +17.5 dB while delta rose +8.4, alpha +5.7 and beta +2.0. The
     contamination is theta-weighted, so every guard dreamy owns points the wrong way — both
     `clearOfFastBands` (theta minus beta) and `calmLowEnd` (theta minus delta) open WIDER during
     the artifact, and blink gating never fires because the worst frames scored 0-2 on blink.

     The question that should separate them is not how loud theta is but whether theta is a PEAK.
     A real theta rhythm is a localised bump; loose-electrode and movement artifact is a smear that
     lifts a whole region at once. Fitting the 1/f line across 2-12 Hz and taking the largest
     residual inside 4-7 Hz distinguishes exactly that: a uniform lift is absorbed by the fit and
     leaves almost no residual, while a genuine bump survives it.

     Logged first, wired into scoring second, and only once the recordings show the two cases
     actually separating. */
    private var thetaShapeBins: [Int] = []
    private var thetaShapeFreqs: [Double] = []
    private var latestThetaProminenceDb: Double = 0.0
    private var latestThetaPeakHz: Double = 0.0

    //peak must clear the fitted 1/f background by this much before it counts as a rhythm
    private let dominantMinProminenceDb: Double = 3.0

    /* Artifact gates. Stricter than elsewhere because the bottom of this search sits right where
     blink energy lives — a blink would otherwise read as a big slow "rhythm". */
    private let dominantBlinkGatePct: Double = 35.0
    private let dominantTensionGatePct: Double = 50.0

    /* Time constants in SECONDS, not per-call weights. This runs on the EEG packet cadence
     rather than the publish cadence, so a fixed per-call weight would mean different real-world
     smoothing on different devices and packet rates. */
    private let dominantFastSeconds: Double = 7.0
    private let dominantSlowSeconds: Double = 120.0
    /* Warm-up for the slow tracker — see updateDominantRhythm. Duration, not sample count: this
     runs on packet cadence (~21/sec), so a count-based window closes in a fraction of a second and
     samples one instant many times over rather than sampling real variation. */
    private let dominantWarmupSeconds: Double = 20.0
    private let dominantWarmupMinSamples: Int = 24
    private let dominantWarmupMaxSamples: Int = 600

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

        //full-spectrum search table for the dominant-rhythm tracker
        for bin in 0..<(fftBins / 2) {
            let hz = Double(bin) * binWidthHz
            guard hz >= dominantLowHz, hz <= dominantHighHz else { continue }
            dominantBins.append(bin)
            dominantFreqs.append(hz)
        }

        //shape window for the theta prominence diagnostic
        for bin in 0..<(fftBins / 2) {
            let hz = Double(bin) * binWidthHz
            guard hz >= thetaShapeLowHz, hz <= thetaShapeHighHz else { continue }
            thetaShapeBins.append(bin)
            thetaShapeFreqs.append(hz)
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
        quiet: Double,
        quietDb: Double
    ) {
        /* REJECT THE UNINITIALISED FRAME.

         On the first publish after the 256-sample buffer fills, the band levels can arrive as five
         exact zeros. That is not a silent brain, it is no measurement at all — but the detrending
         happily fits a flat line through it and returns five zero residuals, so alphaLead comes out
         at exactly 0.0 dB, which sits two thirds of the way up meditation's ramp. Observed live:
         `raw D: 0.0 T: 0.0 A: 0.0 B: 0.0 G: 0.0` with `gate:0.67` on no data whatsoever.

         Any real dB spectrum has some spread between bands; five identical values means the frame
         never got filled. Cheap to test, and it keeps a garbage frame from reaching the scorers at
         the one moment the user is most likely to be looking at the display. */
        let levels = [delta, theta, alpha, beta, gamma]
        guard levels.allSatisfy({ $0.isFinite }) else { return }
        guard let lo = levels.min(), let hi = levels.max(), hi - lo > 1e-9 else { return }
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
            quiet: smoothedQuiet,
            quietDb: quietDb.isFinite ? quietDb : 0.0
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

    /* The dominant-rhythm tracker needs the FULL spectrum, not the band-passed detail one — its
     search reaches down to 5 Hz, below the detail window's floor. Call before
     processDetailSpectrum so the published rhythm belongs to the same frame as the scores. */
    /* Broadband, four-sensor. Only the dominant-rhythm tracker reads this now — it was tuned
     against the whole-head average and there is no evidence yet that moving it helps. */
    func processFullSpectrum(_ spectrum: [Double]) {
        guard !spectrum.isEmpty, !dominantBins.isEmpty else { return }
        updateDominantRhythm(fullSpectrum: spectrum, now: Date())
    }

    /* AF7 + AF8 only. Theta prominence must read the same spectrum theta's amplitude came from,
     otherwise dreamy scores its size from the forehead and its shape from the whole head. */
    func processFrontalSpectrum(_ spectrum: [Double]) {
        guard !spectrum.isEmpty else { return }
        updateThetaProminence(fullSpectrum: spectrum)
    }

    /* How far the strongest 4-7 Hz bin stands above the 1/f line fitted across 2-12 Hz.

     Deliberately NOT gated on blink or tension, unlike the rhythm tracker. The whole point is to
     see what this reads during contaminated frames, so screening those out would remove the
     measurement of interest. */
    private func updateThetaProminence(fullSpectrum spectrum: [Double]) {
        guard !thetaShapeBins.isEmpty else { return }

        let points = thetaShapeBins.enumerated().compactMap { i, bin -> (hz: Double, power: Double)? in
            guard bin < spectrum.count else { return nil }
            let power = max(0.0, spectrum[bin])
            guard power > 1e-12 else { return nil }
            return (hz: thetaShapeFreqs[i], power: power)
        }

        let flattened = flattenedDbValues(points)
        guard flattened.count >= 3 else { return }

        var best: (hz: Double, db: Double)? = nil
        for point in flattened where point.hz >= thetaPeakLowHz && point.hz <= thetaPeakHighHz {
            if best == nil || point.db > best!.db { best = point }
        }

        guard let peak = best, peak.db.isFinite else { return }
        latestThetaProminenceDb = peak.db
        latestThetaPeakHz = peak.hz
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
        lastRhythmHz = 0
        lastRhythmSlowHz = 0
        //each test set is a different person-session; identity must not carry over
        fastDominantHz = 0
        slowDominantHz = 0
        dominantWarmup.removeAll()
        dominantWarmupStart = nil
        dominantWarmupComplete = false
        dominantSampleCount = 0
        lastDominantUpdate = nil
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
            timestamp: now
        )
    }

    /* WHERE THE DOMINANT RHYTHM SITS, RIGHT NOW.

     This replaces the old alpha-pace finder, which searched only 7-13 Hz inside the band-passed
     detail spectrum. Two problems with that: a drowsy brain's strongest rhythm is theta at 4-7 Hz,
     which is below the search floor AND below the detail window, so on a tired recording it was
     reporting whichever weak bump happened to exist in a range where nothing was happening. That
     is why "tired" came back at 10.95 Hz — higher than deep meditation — which is backwards.

     So it now reads the FULL spectrum across 5-20 Hz. Measured on the recorded sets, opening the
     search down to 5 Hz moves falling-asleep from 14.69 Hz to 10.88 and sleeping from 13.90 to
     11.88, while coding stays put at 15.5 — the deep drowsy states become visible without
     disturbing anything else. The ordering across the corpus then runs meditation 9.6, tired 10.3,
     falling asleep 10.9, sleeping 11.9, reading 13.4, typing 14.1, coding 15.5.

     The detail window itself stays at 8-20. Widening THAT made tilt worse (focus-vs-rest fell
     from 0.67 to 0.53), because its cleanliness is exactly what gives the centroid its power.
     Two measurements, two windows, on purpose.

     WHITENED FIRST. Without removing the 1/f slope the lowest bin in the range wins almost every
     frame, because power falls off as roughly 1/f^2 regardless of what the brain is doing. */
    private func updateDominantRhythm(fullSpectrum spectrum: [Double], now: Date) {

        //a blink is a large slow transient sitting right on top of the 5-7 Hz end of the search
        guard latestBlinkPct < dominantBlinkGatePct else { return }
        guard latestTensionPct < dominantTensionGatePct else { return }

        let points = dominantBins.enumerated().compactMap { i, bin -> (hz: Double, power: Double)? in
            guard bin < spectrum.count else { return nil }
            let power = max(0.0, spectrum[bin])
            guard power > 1e-12 else { return nil }
            return (hz: dominantFreqs[i], power: power)
        }

        let flattened = flattenedDbValues(points)
        guard flattened.count >= 3 else { return }

        var peakIndex = 0
        for (i, point) in flattened.enumerated() where point.db > flattened[peakIndex].db {
            peakIndex = i
        }

        /* Least squares puts the mean residual at zero, so the peak's own residual IS its
         prominence above the fitted background. A flat band still has a maximum bin; without
         this guard the tracker would follow noise. */
        guard flattened[peakIndex].db >= dominantMinProminenceDb else { return }

        //sub-bin location, so the value is not quantised to the bin grid
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
        guard estimateHz.isFinite else { return }

        /* TWO TIMESCALES OFF ONE MEASUREMENT.

         Fast is a state signal — it should follow you from meditation into work within a few
         seconds, and it is what sonification should listen to. Slow is identity: where your
         rhythm lives across a whole session, changing rarely enough to set up an instrument
         rather than play one. */

        //clamped so a long gap (headset dropout, app backgrounded) cannot snap either value
        let dt = min(max(now.timeIntervalSince(lastDominantUpdate ?? now), 0.0), 1.0)

        /* Fast needs no warm-up. Its 7-second constant washes out any starting value within a
         handful of seconds, and pinning it during warm-up would only stop it doing its job. */
        if lastDominantUpdate == nil {
            fastDominantHz = estimateHz
        } else {
            fastDominantHz += (1 - exp(-dt / dominantFastSeconds)) * (estimateHz - fastDominantHz)
        }

        /* SLOW IS SEEDED FROM A MEDIAN OVER REAL TIME, NOT OVER A SAMPLE COUNT.

         The original seeded from whatever the first accepted estimate happened to be. With a
         120-second constant that one moment then takes four to six minutes to decay out — most of
         a session, and precisely the window in which an identity value is supposed to be usable.
         Measured: the Athena opened at 6.98 Hz while its fast value was already at 12.26.

         The first repair — median of the first 12 samples — was the right idea measured against
         the wrong clock. This runs on packet cadence, roughly 21 packets a second, so 12 samples
         is about half a second. Twelve looks at the same instant is not twelve independent looks,
         and the Muse S duly seeded at 14.18 Hz against a fast value of 12.12 and spent the next
         ninety seconds decaying toward the 8-10 Hz the session actually lived at.

         So the window is now a DURATION. Twenty seconds of accepted estimates spans real
         variation, and the sample floor stops a heavily-gated stretch from ending warm-up early on
         a handful of readings. The running median publishes throughout, so the value is usable
         from the first second and cannot be dragged by one outlier. */
        if dominantWarmupComplete {
            slowDominantHz += (1 - exp(-dt / dominantSlowSeconds)) * (estimateHz - slowDominantHz)
        } else {
            let started = dominantWarmupStart ?? now
            if dominantWarmupStart == nil { dominantWarmupStart = started }
            if dominantWarmup.count < dominantWarmupMaxSamples {
                dominantWarmup.append(estimateHz)
            }
            slowDominantHz = Self.median(of: dominantWarmup)

            if now.timeIntervalSince(started) >= dominantWarmupSeconds,
               dominantWarmup.count >= dominantWarmupMinSamples {
                dominantWarmupComplete = true
                dominantWarmup.removeAll(keepingCapacity: false)
            }
        }

        dominantSampleCount += 1
        lastDominantUpdate = now
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2.0 : s[mid]
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

        return invRamp(recentSD, low: stabilityLowSD, high: stabilityHighSD)
    }

    //MARK: - Runtime tuning

    /* String-keyed runtime tuning for the app's tuning panel. Analyzer-level keys are handled
     here; anything else is forwarded to the scorer. Keys match XvEEGStateTuningParameter.all
     in XvMuse.swift — keep the lists in sync. Returns false for unknown keys. */
    @discardableResult
    func setTuning(key: String, value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch key {
        case "gates.cleanThreshold": cleanThreshold = value
        case "gates.scoreSmoothing": scoreSmoothing = value
        case "gates.blockedFadeSmoothing": blockedFadeSmoothing = value
        case "gates.stabilityLowSD": stabilityLowSD = value
        case "gates.stabilityHighSD": stabilityHighSD = value
        case "dreamy.tensionDampOnset": RelaxedStateGate.tensionOnset = value
        case "dreamy.tensionDampFull": RelaxedStateGate.tensionFull = value
        case "dreamy.tensionDampFloor": RelaxedStateGate.floor = value
        default: return scorer.setTuning(key: key, value: value)
        }
        return true
    }

    /* Live per-term breakdown for the tuning panel: every gate/support term of the three
     scores plus the signal-quality gates, published at the score cadence so the panel can
     show WHICH term is limiting a score in real time. */
    private func buildTuningReadout(blocked: Bool) -> [String: Double] {
        return [
            "med.gate": scorer.medGate,
            "med.centroid": scorer.meditationAlphaCentroid,
            "med.organized": scorer.meditationOrganized,
            "med.steady": scorer.meditationHoldingSteady,
            "med.alphaLeadDb": scorer.meditationAlphaLeadDb,

            "focus.fast": scorer.focusFastCentroid,
            "focus.calm": scorer.focusCalmCentroid,
            "focus.broad": scorer.focusBroadEnough,
            "focus.steady": scorer.focusHoldingSteady,
            "focus.notAlphaLed": scorer.focusNotAlphaLed,

            "dreamy.thetaLeads": scorer.dreamyGate,
            "dreamy.vsFast": scorer.dreamyClearOfFastBands,
            "dreamy.notFast": scorer.dreamyNotRunningFast,
            "dreamy.rhythm": scorer.dreamyLooksLikeRhythm,
            "dreamy.calmGamma": scorer.dreamyCalmGamma,
            "dreamy.lowEnd": scorer.dreamyCalmLowEnd,
            "dreamy.thetaLeadDb": scorer.dreamySmoothedThetaLeadDb,

            "gate.clean": latestCleanPct,
            "gate.effectiveClean": latestEffectiveCleanPct,
            "gate.tension": latestTensionPct,
            "gate.blink": latestBlinkPct,
            "gate.blocked": blocked ? 1.0 : 0.0,
        ]
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
            thetaProminenceDb: latestThetaProminenceDb,
            smoothing: scoreSmoothing
        )

        lastTiltHz = features.centroidHz
        lastSteadiness = steadiness
        lastIntensity = intensity
        lastSpreadHz = features.spreadHz
        lastConfidence = cleanConfidence01
        lastRhythmHz = fastDominantHz
        lastRhythmSlowHz = slowDominantHz

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
            rhythmHz: fastDominantHz,
            rhythmSlowHz: slowDominantHz
        )

        delegate?.didReceiveStateTuningReadout(buildTuningReadout(blocked: false))

        logState(features: features, scores: scores, now: now)
    }

    private func publishBlockedFadeIfDue(
        now: Date,
        liveTiltHz: Double? = nil,
        liveIntensity: Double? = nil,
        liveSpreadHz: Double? = nil,
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
            rhythmHz: lastRhythmHz,
            rhythmSlowHz: lastRhythmSlowHz
        )

        //keep the tuning panel's gate strip live while blocked — the whole point is seeing
        //WHEN artifact gating (not the formulas) is what is suppressing the scores
        delegate?.didReceiveStateTuningReadout(buildTuningReadout(blocked: true))

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

        //sampled on EVERY publish, ahead of the once-a-second throttle below, so the summaries
        //describe the real distribution rather than a once-per-second slice of it
        accumulateStateSamples(scores: scores)
        emitStateSummariesIfDue(now: now)

        if let last = lastLogTime, now.timeIntervalSince(last) < logInterval { return }
        lastLogTime = now
        guard logStateDetail else { return }

        let elapsed = now.timeIntervalSince(launchTime)
        logFocus(scores: scores, elapsed: elapsed)

        //MED and DREAMY silenced while FOCUS is being tuned — flip back on when their turn comes
        if logMeditationAndDreamy {
            logMeditation(scores: scores, elapsed: elapsed)
            logDreamy(scores: scores, elapsed: elapsed)
        }
    }

    private func accumulateStateSamples(scores: (meditation: Double, focus: Double, dreamy: Double)) {
        guard latestBands != nil else {
            dreamyRejectedFrames += 1
            return
        }

        let lowEndTerm = scorer.dreamyBaseOffset + (scorer.dreamySupportSpan * scorer.dreamySupport)
        let terms: [(name: String, value: Double)] = [
            ("thetaLead", scorer.dreamyGate),
            ("vsFast", scorer.dreamyCredibility),
            ("notFast", scorer.dreamyNotRunningFast),
            ("rhythm", scorer.dreamyLooksLikeRhythm),
            ("calmGamma", scorer.dreamyCalmGamma),
            ("lowEnd", lowEndTerm)
        ]

        dreamySamples.append(DreamySample(
            score: scores.dreamy,
            smoothedLead: scorer.dreamySmoothedThetaLeadDb,
            leadGate: scorer.dreamyGate,
            vsFast: scorer.dreamyCredibility,
            notFast: scorer.dreamyNotRunningFast,
            rhythm: scorer.dreamyLooksLikeRhythm,
            calmGamma: scorer.dreamyCalmGamma,
            lowEnd: lowEndTerm,
            limitName: terms.min { $0.value < $1.value }.map(\.name) ?? "-",
            tension: latestTensionPct,
            blink: latestBlinkPct,
            clean: latestEffectiveCleanPct
        ))

        /* Focus is shape × support, and shape is the better of two paths — so the binding
         constraint is whichever half of the product is smaller, then the weak spot inside it. */
        let focusSupportTerm = scorer.focusBaseOffset + (scorer.focusSupportSpan * scorer.focusSupport)
        let focusLimit: String
        if scorer.focusGate < focusSupportTerm {
            focusLimit = scorer.focusFastCentroid >= scorer.focusCalmCentroid ? "fastPath" : "calmPath"
        } else {
            focusLimit = scorer.focusBroadEnough < scorer.focusHoldingSteady ? "broad" : "steady"
        }
        focusSamples.append(FocusSample(
            score: scores.focus,
            shape: scorer.focusGate,
            fast: scorer.focusFastCentroid,
            calm: scorer.focusCalmCentroid,
            notAlphaLed: scorer.focusNotAlphaLed,
            broad: scorer.focusBroadEnough,
            steady: scorer.focusHoldingSteady,
            support: scorer.focusSupport,
            limitName: focusLimit,
            tiltHz: scorer.focusTiltOffsetHz,
            spreadHz: scorer.focusSpreadOffsetHz,
            alphaLeadDb: scorer.focusAlphaLeadDb
        ))

        let medSupportTerm = scorer.medBaseOffset + (scorer.medSupportSpan * scorer.medSupport)
        let medLimit: String
        if scorer.medGate < medSupportTerm {
            medLimit = "alphaLead"
        } else {
            let parts: [(String, Double)] = [
                ("centroid", scorer.meditationAlphaCentroid),
                ("organized", scorer.meditationOrganized),
                ("steady", scorer.meditationHoldingSteady)
            ]
            medLimit = parts.min { $0.1 < $1.1 }?.0 ?? "-"
        }
        medSamples.append(MedSample(
            score: scores.meditation,
            alphaLeadDb: scorer.meditationAlphaLeadDb,
            alphaLeads: scorer.medGate,
            centroid: scorer.meditationAlphaCentroid,
            organized: scorer.meditationOrganized,
            steady: scorer.meditationHoldingSteady,
            support: scorer.medSupport,
            limitName: medLimit
        ))
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func topLimit(_ names: [String]) -> (name: String, share: Double) {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        guard let top = counts.max(by: { $0.value < $1.value }), !names.isEmpty else { return ("-", 0) }
        return (top.key, Double(top.value) / Double(names.count) * 100.0)
    }

    /* One line per state per window, carrying the DISTRIBUTION rather than an instant.

     Calibration is a question about where a signal usually sits and how far it swings, which a
     per-second snapshot cannot answer — and the thing most worth knowing is which gate is the
     binding constraint most often, since a product is only ever as large as its smallest term. */
    private func emitStateSummariesIfDue(now: Date) {
        if stateSummaryStart == nil { stateSummaryStart = now }
        guard let start = stateSummaryStart,
              now.timeIntervalSince(start) >= stateSummaryInterval else { return }
        stateSummaryStart = now

        let elapsed = now.timeIntervalSince(launchTime)
        let dreamy = dreamySamples
        let focus = focusSamples
        let med = medSamples
        let rejected = dreamyRejectedFrames
        dreamySamples.removeAll(keepingCapacity: true)
        focusSamples.removeAll(keepingCapacity: true)
        medSamples.removeAll(keepingCapacity: true)
        dreamyRejectedFrames = 0

        guard !dreamy.isEmpty else {
            print(String(format: "STATE SUMMARY | t:%6.1f | NO USABLE FRAMES (%d rejected)",
                         elapsed, rejected))
            return
        }

        func med3(_ values: [Double]) -> Double { percentile(values, 0.5) }

        guard logMeditationAndDreamy else {
            emitFocusSummary(focus: focus, elapsed: elapsed)
            return
        }

        let dreamyScores = dreamy.map(\.score)
        let leads = dreamy.map(\.smoothedLead)
        let dreamyLimit = topLimit(dreamy.map(\.limitName))

        print(String(
            format: "DREAMY SUMMARY | t:%6.1f | frames %3d (rejected %2d) | dreamy med %3.0f p10 %3.0f p90 %3.0f | lead sm med %+5.2f p10 %+5.2f p90 %+5.2f | gates med lead %4.2f vsFast %4.2f notFast %4.2f rhythm %4.2f calmGamma %4.2f lowEnd %4.2f | LIMIT %@ %2.0f%% | tension %3.0f blink %3.0f clean %3.0f",
            elapsed,
            dreamy.count, rejected,
            med3(dreamyScores), percentile(dreamyScores, 0.1), percentile(dreamyScores, 0.9),
            med3(leads), percentile(leads, 0.1), percentile(leads, 0.9),
            med3(dreamy.map(\.leadGate)), med3(dreamy.map(\.vsFast)),
            med3(dreamy.map(\.notFast)), med3(dreamy.map(\.rhythm)),
            med3(dreamy.map(\.calmGamma)), med3(dreamy.map(\.lowEnd)),
            dreamyLimit.name, dreamyLimit.share,
            med3(dreamy.map(\.tension)), med3(dreamy.map(\.blink)), med3(dreamy.map(\.clean))
        ))

        emitFocusSummary(focus: focus, elapsed: elapsed)

        let medScores = med.map(\.score)
        let medLimit = topLimit(med.map(\.limitName))
        print(String(
            format: "MED SUMMARY    | t:%6.1f | med %3.0f p10 %3.0f p90 %3.0f | alphaLead med %+5.2fdB gate %4.2f | centroid %4.2f organized %4.2f steady %4.2f | LIMIT %@ %2.0f%%",
            elapsed,
            med3(medScores), percentile(medScores, 0.1), percentile(medScores, 0.9),
            med3(med.map(\.alphaLeadDb)), med3(med.map(\.alphaLeads)),
            med3(med.map(\.centroid)), med3(med.map(\.organized)), med3(med.map(\.steady)),
            medLimit.name, medLimit.share
        ))
    }

    /* FOCUS SUMMARY — the distribution over the window, plus the raw measurements' percentiles.

     Split out so focus-only mode can print it without the meditation and dreamy summaries. */
    private func emitFocusSummary(focus: [FocusSample], elapsed: TimeInterval) {
        guard !focus.isEmpty else { return }
        func med3(_ values: [Double]) -> Double { percentile(values, 0.5) }

        let focusScores = focus.map(\.score)
        let focusLimit = topLimit(focus.map(\.limitName))
        let tilts = focus.map(\.tiltHz)
        print(String(
            format: "FOCUS SUMMARY  | t:%6.1f | focus med %3.0f p10 %3.0f p90 %3.0f | shape med %4.2f (fast %4.2f calm %4.2f notAlpha %4.2f) | broad %4.2f steady %4.2f | LIMIT %@ %2.0f%%",
            elapsed,
            med3(focusScores), percentile(focusScores, 0.1), percentile(focusScores, 0.9),
            med3(focus.map(\.shape)), med3(focus.map(\.fast)), med3(focus.map(\.calm)),
            med3(focus.map(\.notAlphaLed)),
            med3(focus.map(\.broad)), med3(focus.map(\.steady)),
            focusLimit.name, focusLimit.share
        ))

        /* The tuning line. p90 of tilt is the number a new FAST TILT HI is read off: set the high
         anchor near it and the fast term saturates on the best moments instead of never. */
        print(String(
            format: "   tuning | tilt p10 %+5.2f med %+5.2f p90 %+5.2f (FAST %+.1f..%+.1f) | spread p10 %+5.2f med %+5.2f p90 %+5.2f (BROAD %+.1f..%+.1f) | αlead med %+5.2f (¬α %+.1f..%+.1f)",
            percentile(tilts, 0.1), med3(tilts), percentile(tilts, 0.9),
            scorer.focusTiltOffsetLowHz, scorer.focusTiltOffsetHighHz,
            percentile(focus.map(\.spreadHz), 0.1), med3(focus.map(\.spreadHz)),
            percentile(focus.map(\.spreadHz), 0.9),
            scorer.broadOffsetLowHz, scorer.broadOffsetHighHz,
            med3(focus.map(\.alphaLeadDb)),
            scorer.focusNotAlphaLedLowDb, scorer.focusNotAlphaLedHighDb
        ))

    }

    /* FOCUS DIAGNOSTIC — same design as dreamy's: every multiplier, then the binding one.

     Focus is shape × support, where shape is the BETTER of two paths (fast tilt, or calm-but-broad
     with alpha not leading), so unlike dreamy a single weak term does not necessarily matter —
     only the weak term of the winning path does. */
    private func logFocus(
        scores: (meditation: Double, focus: Double, dreamy: Double),
        elapsed: TimeInterval
    ) {
        /* Line 1: the score and the gate values — WHICH term is limiting.
         Line 2: the raw Hz/dB measurements and the thresholds acting on them — WHERE to move a
         threshold. The gate values alone are not enough: a fast term of 0.51 is consistent with
         many centroid positions depending on the anchors, so the offsets have to be printed too. */
        print(String(
            format: "FOCUS  %3.0f | shape x%4.2f (fast %4.2f | calm %4.2f = ctr %4.2f × broad %4.2f × notAlpha %4.2f) | support %4.2f (broad %4.2f steady %4.2f)",
            scores.focus,
            scorer.focusGate,
            scorer.focusFastCentroid,
            scorer.focusCalmCentroid * scorer.focusBroadEnough * scorer.focusNotAlphaLed,
            scorer.focusCalmCentroid, scorer.focusBroadEnough, scorer.focusNotAlphaLed,
            scorer.focusSupport,
            scorer.focusBroadEnough, scorer.focusHoldingSteady
        ))

        print(String(
            format: "   raw | tilt %+5.2fHz (FAST ramp %+.1f..%+.1f) | spread %+5.2fHz (BROAD ramp %+.1f..%+.1f) | αlead %+5.2fdB (¬α ramp %+.1f..%+.1f) | centroid %5.2f null %5.2f | tension %3.0f blink %3.0f",
            scorer.focusTiltOffsetHz,
            scorer.focusTiltOffsetLowHz, scorer.focusTiltOffsetHighHz,
            scorer.focusSpreadOffsetHz,
            scorer.broadOffsetLowHz, scorer.broadOffsetHighHz,
            scorer.focusAlphaLeadDb,
            scorer.focusNotAlphaLedLowDb, scorer.focusNotAlphaLedHighDb,
            scorer.focusNullCentroidHz + scorer.focusTiltOffsetHz,
            scorer.focusNullCentroidHz,
            latestTensionPct, latestBlinkPct
        ))
    }

    /* MEDITATION DIAGNOSTIC. awake is measured but not multiplied in — printed so its absence
     from the product can be verified rather than trusted. */
    private func logMeditation(
        scores: (meditation: Double, focus: Double, dreamy: Double),
        elapsed: TimeInterval
    ) {
        print(String(
            format: "MED    %3.0f | alphaLead %+5.2fdB gate x%4.2f (opens %+.1f..%+.1f) | support %4.2f (centroid %4.2f organized %4.2f steady %4.2f) | awake %4.2f (unused)",
            scores.meditation,
            scorer.meditationAlphaLeadDb,
            scorer.medGate,
            scorer.meditationAlphaLeadLowDb, scorer.meditationAlphaLeadHighDb,
            scorer.medSupport,
            scorer.meditationAlphaCentroid, scorer.meditationOrganized, scorer.meditationHoldingSteady,
            scorer.meditationAwakeEnough
        ))
    }

    /* DREAMY DIAGNOSTIC.

     The score is a product of five terms, so it is only ever as large as its smallest one — and a
     bare score says "low" without saying which term did it. This prints every multiplier, then
     names the weakest, so the answer to "why isn't dreamy moving?" is on the line itself.

     Reading it: `x1.00` means that term is fully open and contributing nothing to the problem.
     LIMIT names the term to look at. The second line carries the raw evidence behind each gate,
     with the threshold it has to clear, so a term sitting at 0 can be traced to a number.

     Note theta and its prominence are now measured on the FRONTAL pair (AF7+AF8) rather than all
     four sensors, so these numbers are not comparable with dreamy logs from before 9 Aug 2026. */
    private func logDreamy(
        scores: (meditation: Double, focus: Double, dreamy: Double),
        elapsed: TimeInterval
    ) {
        guard let bands = latestBands else {
            print(String(format: "DREAMY | t:%6.1f | NO BAND DATA — frames rejected upstream", elapsed))
            return
        }

        //the low-end term enters the product scaled, not raw, so weigh it the way the score does
        let lowEndTerm = scorer.dreamyBaseOffset + (scorer.dreamySupportSpan * scorer.dreamySupport)

        let terms: [(name: String, value: Double)] = [
            ("thetaLead", scorer.dreamyGate),
            ("vsBeta", scorer.dreamyCredibility),
            ("notFast", scorer.dreamyNotRunningFast),
            ("rhythm", scorer.dreamyLooksLikeRhythm),
            ("calmGamma", scorer.dreamyCalmGamma),
            ("lowEnd", lowEndTerm)
        ]
        let limit = terms.min { $0.value < $1.value }.map { $0.name } ?? "-"
        let weakest = terms.map(\.value).min() ?? 1.0

        /* What the gates alone are asking for this instant, before tension damping and before the
         score's own time smoothing. A large gap between this and the published score means the
         gates have opened but the smoothing has not caught up yet — worth knowing when the reading
         seems to lag what you are actually feeling. */
        let gateProduct = terms.reduce(1.0) { $0 * $1.value } * 100.0

        print(String(
            format: "DREAMY %3.0f (gates want %3.0f) | thetaLead x%4.2f | vsBeta x%4.2f | notFast x%4.2f | rhythm x%4.2f | calmGamma x%4.2f | lowEnd x%4.2f |%@",
            scores.dreamy,
            gateProduct,
            scorer.dreamyGate,
            scorer.dreamyCredibility,
            scorer.dreamyNotRunningFast,
            scorer.dreamyLooksLikeRhythm,
            scorer.dreamyCalmGamma,
            lowEndTerm,
            weakest > 0.85 ? " all open" : " LIMIT \(limit)"
        ))

        print(String(
            format: "   why | lead %+5.2fdB sm %+5.2f (opens %+.1f..%+.1f) | vsFast sm %+5.2f (opens -1.0..2.0) | tilt %+5.2fHz (vetoes %.1f..%.1f) | prom %5.2fdB @%4.1fHz (vetoes %.1f..%.1f) | gamma %+5.2fdB (vetoes %.1f..%.1f) | T-D %+5.2f | tension %3.0f blink %3.0f clean %3.0f damp %4.2f",
            scorer.dreamyThetaLeadDb,
            scorer.dreamySmoothedThetaLeadDb,
            scorer.dreamyThetaLeadLowDb, scorer.dreamyThetaLeadHighDb,
            scorer.dreamyThetaVsFastDb,
            scorer.dreamyTiltOffsetHz,
            scorer.dreamyTiltOffsetOnsetHz, scorer.dreamyTiltOffsetFullHz,
            latestThetaProminenceDb, latestThetaPeakHz,
            scorer.dreamyProminenceLowDb, scorer.dreamyProminenceHighDb,
            scorer.dreamyGammaDb,
            scorer.dreamyGammaLowDb, scorer.dreamyGammaHighDb,
            scorer.dreamyThetaVsDeltaDb,
            latestTensionPct, latestBlinkPct, latestEffectiveCleanPct,
            RelaxedStateGate.damping(forTension: latestTensionPct)
        ))

        //raw band levels last, for when the residuals look wrong and the source needs checking
        print(String(
            format: "   bands | raw D %5.1f T %5.1f A %5.1f B %5.1f G %5.1f | resid D %+5.1f T %+5.1f A %+5.1f B %+5.1f | quiet %3.0f",
            bands.delta, bands.theta, bands.alpha, bands.beta, bands.gamma,
            bands.deltaResidual, bands.thetaResidual, bands.alphaResidual, bands.betaResidual,
            bands.quiet
        ))
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
