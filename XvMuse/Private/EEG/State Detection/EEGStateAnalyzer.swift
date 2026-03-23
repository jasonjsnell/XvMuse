//
//  EEGStateAnalyzer.swift
//  XvMuse
//

import Foundation

protocol EEGStateAnalyzerDelegate: AnyObject {
    func didReceiveBaselineProgress(_ progress: Double)
    func didReceiveStateScores(meditation: Double, focus: Double, dreamy: Double)
}

final class EEGStateAnalyzer {
    weak var delegate: EEGStateAnalyzerDelegate?

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

    private let scorer = EEGStateScorer()

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
        delegate?.didReceiveStateScores(meditation: scores.meditation, focus: scores.focus, dreamy: scores.dreamy)

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
        delegate?.didReceiveStateScores(meditation: scores.meditation, focus: scores.focus, dreamy: scores.dreamy)

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
