//
//  EEGStateAnalyzer.swift
//  XvMuse
//

import Foundation

protocol EEGStateAnalyzerDelegate: AnyObject {
    func didReceiveBrainwaveState(meditation: Double, focus: Double, dreamy: Double)
}

/* Measures brainwave states from the live spectrum.

 FLOW
   detail spectrum (already band-passed before the FFT, forehead sensors only)
     -> undo the filter's own frequency response
     -> reduce to centroid, spread, and total power
     -> combine with full-spectrum band balance
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

    //full-spectrum band levels in dB
    private var latestBands: BandBalance? = nil
    private var smoothedQuiet: Double = 0.0
    private let quietSmoothing: Double = 0.15

    //MARK: - Detail window mapping

    private let usableBins: [Int]       //spectrum indices inside the trusted part of the band
    private let usableFreqs: [Double]   //centre frequency of each, in Hz
    private let compensation: [Double]  //1 / |H(f)|^2, undoes the band-pass filter's own shape

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

        print("EEGStateAnalyzer: detail window \(lowHz)-\(highHz) Hz, \(bins.count) usable bins")
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

    /* Full-spectrum band levels in dB. Call before processDetailSpectrum; the stored values are
     used on the next publish. */
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
        smoothedQuiet += quietSmoothing * (quiet - smoothedQuiet)

        latestBands = BandBalance(
            delta: delta,
            theta: theta,
            alpha: alpha,
            beta: beta,
            gamma: gamma,
            quiet: smoothedQuiet
        )
    }

    func processDetailSpectrum(_ spectrum: [Double]) {

        guard !spectrum.isEmpty, !usableBins.isEmpty else { return }

        let now = Date()

        guard latestEffectiveCleanPct >= cleanThreshold else { return }
        guard let features = measure(spectrum, at: now) else { return }

        trackStability(features, now: now)
        publishIfDue(features, now: now)
    }

    func reset() {
        recentCentroids.removeAll()
        lastPublish = nil
        lastLogTime = nil
        latestEffectiveCleanPct = 0
        latestTensionPct = 0
        latestBands = nil
        smoothedQuiet = 0
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

    //MARK: - Stability

    private func trackStability(_ features: DetailFeatures, now: Date) {
        recentCentroids.append((features.centroidHz, now))
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

        let scores = scorer.applyStateScores(
            centroidHz: features.centroidHz,
            spreadHz: features.spreadHz,
            logPower: features.logPower,
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

        logState(features: features, scores: scores, now: now)
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
            format: "STATE | t:%6.1f | foc:%3.0f med:%3.0f drm:%3.0f | cen:%5.2fHz | spr:%5.2fHz | logPow:%5.2f | stab:%4.2f | clean:%3.0f tens:%3.0f",
            elapsed,
            scores.focus, scores.meditation, scores.dreamy,
            features.centroidHz,
            features.spreadHz,
            features.logPower,
            centroidStability,
            latestEffectiveCleanPct,
            latestTensionPct
        ))

        print(String(
            format: "STATE DETAIL | t:%6.1f | focGate:%4.2f sup:%4.2f | medGate:%4.2f sup:%4.2f | drmGate:%4.2f cred:%4.2f sup:%4.2f",
            elapsed,
            scorer.focusGate, scorer.focusSupport,
            scorer.medGate, scorer.medSupport,
            scorer.dreamyGate, scorer.dreamyCredibility, scorer.dreamySupport
        ))

        if let bands = latestBands {
            let strongest = max(max(bands.delta, bands.alpha), max(bands.beta, bands.gamma))
            print(String(
                format: "STATE BANDS | t:%6.1f | D%6.1f T%6.1f A%6.1f B%6.1f G%6.1f | T-best:%+5.1f | quiet(sm):%3.0f",
                elapsed,
                bands.delta, bands.theta, bands.alpha, bands.beta, bands.gamma,
                bands.theta - strongest,
                bands.quiet
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

    private func ramp(_ x: Double, low: Double, high: Double) -> Double {
        guard high > low else { return x >= high ? 1.0 : 0.0 }
        return clamp01((x - low) / (high - low))
    }

    private func invRamp(_ x: Double, low: Double, high: Double) -> Double {
        1.0 - ramp(x, low: low, high: high)
    }
}
