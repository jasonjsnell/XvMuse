//
//  EEGStateScorer.swift
//  XvMuse
//

import Foundation

/* Turns live spectrum measurements into three state scores, 0-100.

 Quiet is not here; it stays an absolute low-activity reading across the whole bandwidth,
 computed in XvEEGAnalysis. */

final class EEGStateScorer {

    private(set) var meditationScore: Double = 0.0
    private(set) var focusScore: Double = 0.0
    private(set) var dreamyScore: Double = 0.0

    /* Last breakdown of each score, for diagnostics only. Each state is gate × support, so the
     log needs both: a low score with a healthy gate means the support was weak, while a zero gate
     means the defining evidence was simply absent. */
    private(set) var focusGate: Double = 0.0
    private(set) var focusSupport: Double = 0.0
    private(set) var medGate: Double = 0.0
    private(set) var medSupport: Double = 0.0
    private(set) var dreamyGate: Double = 0.0
    private(set) var dreamyCredibility: Double = 0.0
    private(set) var dreamySupport: Double = 0.0

    //MARK: - Tunables

    var focusCentroidLowHz: Double = 12.0
    var focusCentroidHighHz: Double = 16.5

    var meditationCentroidCenterHz: Double = 10.0
    var meditationCentroidRadiusHz: Double = 3.5

    var narrowSpreadLowHz: Double = 0.8
    var narrowSpreadHighHz: Double = 2.6

    var broadSpreadLowHz: Double = 1.5
    var broadSpreadHighHz: Double = 4.0

    func reset() {
        meditationScore = 0.0
        focusScore = 0.0
        dreamyScore = 0.0
        focusGate = 0.0
        focusSupport = 0.0
        medGate = 0.0
        medSupport = 0.0
        dreamyGate = 0.0
        dreamyCredibility = 0.0
        dreamySupport = 0.0
    }

    func applyStateScores(
        centroidHz: Double,
        spreadHz: Double,
        logPower: Double,
        stability: Double,
        bands: BandBalance?,
        tension: Double,
        smoothing: Double
    ) -> (meditation: Double, focus: Double, dreamy: Double) {

        //Kept in the API because it is useful for logging/tuning even if not scored yet.
        _ = logPower

        let newFocus = scoreFocus(
            centroidHz: centroidHz,
            spreadHz: spreadHz,
            stability: stability,
            bands: bands
        ) * 100.0

        let newMeditation = scoreMeditation(
            centroidHz: centroidHz,
            spreadHz: spreadHz,
            stability: stability,
            bands: bands
        ) * 100.0

        focusScore = smoothScore(old: focusScore, new: newFocus, factor: smoothing)
        meditationScore = smoothScore(old: meditationScore, new: newMeditation, factor: smoothing)

        //dreamy holds its last value if band data hasn't arrived yet
        if let bands {
            /* Scaled down by muscle tension: a clench rules out drowsy drifting, and it also
             makes the reading untrustworthy. Applied before smoothing so the score eases down
             rather than dropping in one step. */
            let newDreamy = scoreDreamy(bands) * 100.0 * RelaxedStateGate.damping(forTension: tension)
            dreamyScore = smoothScore(old: dreamyScore, new: newDreamy, factor: smoothing)
        }

        return (meditationScore, focusScore, dreamyScore)
    }

    /* Focus: faster detail-window centroid, broadband enough to feel active, and held steady. */
    private func scoreFocus(
        centroidHz: Double,
        spreadHz: Double,
        stability: Double,
        bands: BandBalance?
    ) -> Double {

        let fastCentroid = ramp(centroidHz, low: focusCentroidLowHz, high: focusCentroidHighHz)
        let broadEnough = ramp(spreadHz, low: broadSpreadLowHz, high: broadSpreadHighHz)
        let holdingSteady = clamp01(stability)

        let betaLeads: Double
        if let bands {
            let strongestRival = max(max(bands.delta, bands.theta), max(bands.alpha, bands.gamma))
            betaLeads = ramp(bands.beta - strongestRival, low: -2.0, high: 1.0)
        } else {
            betaLeads = fastCentroid
        }

        let gate = max(fastCentroid, betaLeads)
        let support = (0.40 * broadEnough) + (0.35 * holdingSteady) + (0.25 * betaLeads)

        focusGate = gate
        focusSupport = support

        return clamp01(gate * (0.45 + (0.55 * support)))
    }

    /* Meditation: alpha-led, organized, still activity in the detail window. */
    private func scoreMeditation(
        centroidHz: Double,
        spreadHz: Double,
        stability: Double,
        bands: BandBalance?
    ) -> Double {

        guard let bands else {
            medGate = 0
            medSupport = 0
            return 0
        }

        let strongestRival = max(max(bands.delta, bands.theta), max(bands.beta, bands.gamma))
        let alphaLeads = ramp(bands.alpha - strongestRival, low: -2.0, high: 1.0)

        let alphaCentroid = centered(
            centroidHz,
            center: meditationCentroidCenterHz,
            radius: meditationCentroidRadiusHz
        )
        let organized = invRamp(spreadHz, low: narrowSpreadLowHz, high: narrowSpreadHighHz)
        let holdingSteady = clamp01(stability)

        let support = (0.35 * alphaCentroid) + (0.35 * organized) + (0.30 * holdingSteady)

        medGate = alphaLeads
        medSupport = support

        return clamp01(alphaLeads * (0.40 + (0.60 * support)))
    }

    /* Dreamy: theta-led, quiet, slow activity read from the full spectrum. */
    private func scoreDreamy(_ bands: BandBalance) -> Double {

        let strongestRival = max(max(bands.delta, bands.alpha), max(bands.beta, bands.gamma))
        let thetaLeads = ramp(bands.theta - strongestRival, low: -2.0, high: 1.0)

        //Broadband noise raises beta/gamma too, so theta needs to stand clear of fast bands.
        let clearOfFastBands = ramp(bands.theta - max(bands.beta, bands.gamma), low: -1.0, high: 3.0)

        //Stillness separates real drowsy drift from active cognitive theta.
        let stillnessPresent = ramp(bands.quiet, low: 20.0, high: 50.0)

        //A calm low end. A blink drives delta up and pulls this down.
        let calmLowEnd = ramp(bands.theta - bands.delta, low: -2.0, high: 2.0)

        dreamyGate = thetaLeads
        dreamyCredibility = min(clearOfFastBands, stillnessPresent)
        dreamySupport = calmLowEnd

        return clamp01(
            thetaLeads * clearOfFastBands * stillnessPresent * (0.50 + (0.50 * calmLowEnd))
        )
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

    private func centered(_ x: Double, center: Double, radius: Double) -> Double {
        guard radius > 0 else { return x == center ? 1.0 : 0.0 }
        return clamp01(1.0 - (abs(x - center) / radius))
    }

    private func smoothScore(old: Double, new: Double, factor: Double) -> Double {
        let f = clamp01(factor)
        return (f * new) + ((1.0 - f) * old)
    }
}
