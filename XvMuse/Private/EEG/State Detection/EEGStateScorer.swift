//
//  EEGStateScorer.swift
//  XvMuse
//

import Foundation

/* Turns the measurements into three state scores, 0-100. Quiet is not here — it stays an
 absolute low-activity reading across the whole bandwidth, computed in XvEEGAnalysis.

 FOCUS and MEDITATION come from the detail window: where the energy sits (zCentroid), how much
 there is (zPower), how spread out it is (zSpread), and how still the centroid has been holding
 (stability, 0-1). The first three are z-scores against this person's own running baseline, so
 "high" always means high FOR THEM. They are built from different combinations of those axes
 rather than from opposite ends of one axis, which is what went wrong with the old band-ratio
 version: focus and meditation were near mirror images and measured the same thing twice.

 DREAMY comes from the full-spectrum band balance instead, because it depends on theta and the
 detail window starts above it. It needs no baseline, so it is meaningful immediately. */

final class EEGStateScorer {

    private(set) var meditationScore: Double = 0.0
    private(set) var focusScore: Double = 0.0
    private(set) var dreamyScore: Double = 0.0

    /* Last dreamy breakdown, kept for diagnostics only. Dreamy is the score most likely to be
     wrong for an interesting reason, so the log needs to show which half let it down: the shape
     that says it looks drowsy, or the credibility that says whether to believe it. */
    private(set) var dreamyShape: Double = 0.0
    private(set) var dreamyCredibility: Double = 0.0
    private(set) var dreamyFastBands: Double = 0.0
    private(set) var dreamyStillness: Double = 0.0

    func reset() {
        meditationScore = 0.0
        focusScore = 0.0
        dreamyScore = 0.0
    }

    func applyStateScores(
        zCentroid: Double,
        zPower: Double,
        zSpread: Double,
        stability: Double,
        bands: BandBalance?,
        tension: Double,
        smoothing: Double
    ) -> (meditation: Double, focus: Double, dreamy: Double) {

        let newFocus = scoreFocus(zCentroid: zCentroid, zPower: zPower, stability: stability) * 100.0
        let newMeditation = scoreMeditation(zCentroid: zCentroid, zSpread: zSpread, stability: stability) * 100.0

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

    /* Focus: energy sitting faster than this person's norm, and parked there.
     Stability is what separates genuine task engagement from restless churn — both push the
     centroid up, only one holds it. */
    private func scoreFocus(zCentroid: Double, zPower: Double, stability: Double) -> Double {
        let leaningFast = ramp(zCentroid, low: 0.2, high: 1.2)
        let holdingSteady = clamp01(stability)
        let notFaint = ramp(zPower, low: -1.4, high: -0.4)
        return clamp01(
            (0.50 * leaningFast) +
            (0.35 * holdingSteady) +
            (0.15 * notFaint)
        )
    }

    /* Meditation: an organized rhythm rather than a diffuse smear, held steady near or a little
     below the personal centre. Narrow spread is the positive marker — without it this would just
     be "not focused and not dreamy", which any idle moment would satisfy. */
    private func scoreMeditation(zCentroid: Double, zSpread: Double, stability: Double) -> Double {
        let organized = invRamp(zSpread, low: -0.6, high: 0.4)
        let settled = centered(zCentroid, center: -0.2, radius: 1.0)
        let holdingSteady = clamp01(stability)
        return clamp01(
            (0.45 * organized) +
            (0.30 * settled) +
            (0.25 * holdingSteady)
        )
    }

    /* Dreamy: strong theta with a calm low end, read off the full spectrum.

     SHAPE — does this look like drowsy drifting?
       theta above delta — the low end is calm, so slow activity is real drowsiness rather than
                           eye movement, pulse or motion. A blink blows delta far past theta and
                           collapses this, so a blink cannot fake a dreamy reading.
       theta at or near the top — alpha is the only band allowed above it, and not by much

     CREDIBILITY — should the shape be believed at all?
     Both shape conditions can be satisfied by broadband noise rather than by a brain. Real EEG
     follows a 1/f slope, big and slow down to small and fast, so delta normally sits well above
     theta. Flat broadband noise lifts the small bands proportionally more than the large ones,
     flattening that slope and pushing theta past delta — which looks identical to a clean low
     end. Two independent checks catch it:

       theta clearly above the fast bands — noise is broadband, so it raises beta and gamma along
                                            with everything else. Drowsiness lowers them.
       overall stillness is not absent — noise is loud everywhere at once, so quiet collapses.

     These GATE the score rather than contributing to it. As weighted terms they could only shave
     a few points off a confident false positive; as gates, failing either one takes dreamy down
     regardless of how convincing the shape looks. The weaker of the two caps the result, rather
     than multiplying them together, so one marginal check can't silently halve a good reading.

     Everything except the quiet check is a band-against-band comparison in dB, so overall signal
     strength cancels out and no baseline is needed. */
    private func scoreDreamy(_ bands: BandBalance) -> Double {

        let calmLowEnd = ramp(bands.theta - bands.delta, low: -3.0, high: 3.0)
        let nearTheTop = ramp(bands.theta - bands.alpha, low: -4.0, high: 0.0)
        let shape = (0.55 * calmLowEnd) + (0.45 * nearTheTop)

        let aboveTheFastBands = ramp(bands.theta - max(bands.beta, bands.gamma), low: 0.0, high: 6.0)
        let stillnessPresent = ramp(bands.quiet, low: 15.0, high: 40.0)
        let credibility = min(aboveTheFastBands, stillnessPresent)

        dreamyShape = shape
        dreamyCredibility = credibility
        dreamyFastBands = aboveTheFastBands
        dreamyStillness = stillnessPresent

        return clamp01(shape * credibility)
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


//MARK: - ARCHIVED -

/* Previous scoring, driven by relative band powers (theta/alpha/beta as fractions of total)
 z-scored against a locked baseline. Replaced because in a narrow detail window those three
 fractions must sum to 1, so alpha cannot rise without beta falling — focus and meditation
 collapse into one axis with a sign flip. Kept for reference; not used in the live path. */

final class LegacyEEGStateScorer {
    private(set) var meditationScore: Double = 0.0
    private(set) var focusScore: Double = 0.0
    private(set) var dreamyScore: Double = 0.0

    func reset() {
        meditationScore = 0.0
        focusScore = 0.0
        dreamyScore = 0.0
    }

    func applyStateScores(
        zDelta: Double,
        zTheta: Double,
        zAlpha: Double,
        zBeta: Double,
        smoothing: Double
    ) -> (meditation: Double, focus: Double, dreamy: Double) {
        let newMeditation = scoreMeditation(zTheta: zTheta, zAlpha: zAlpha, zBeta: zBeta) * 100.0
        let newFocus = scoreFocus(zTheta: zTheta, zAlpha: zAlpha, zBeta: zBeta) * 100.0
        let newDreamy = scoreDreamy(zDelta: zDelta, zTheta: zTheta, zAlpha: zAlpha, zBeta: zBeta) * 100.0

        meditationScore = smoothScore(old: meditationScore, new: newMeditation, factor: smoothing)
        focusScore = smoothScore(old: focusScore, new: newFocus, factor: smoothing)
        dreamyScore = smoothScore(old: dreamyScore, new: newDreamy, factor: smoothing)

        return (meditationScore, focusScore, dreamyScore)
    }

    private func scoreMeditation(zTheta: Double, zAlpha: Double, zBeta: Double) -> Double {
        let alphaHigh = ramp(zAlpha, low: 0.2, high: 1.2)
        let betaLow = invRamp(zBeta, low: -0.2, high: 0.8)
        let thetaNearBaseline = centered(zTheta, center: 0.0, radius: 0.9)
        return clamp01((alphaHigh + betaLow + thetaNearBaseline) / 3.0)
    }

    private func scoreFocus(zTheta: Double, zAlpha: Double, zBeta: Double) -> Double {
        let betaHigh = ramp(zBeta, low: 0.2, high: 1.2)
        let alphaLow = invRamp(zAlpha, low: -0.1, high: 0.9)
        let thetaNearBaseline = centered(zTheta, center: 0.0, radius: 0.8)
        return clamp01((betaHigh + alphaLow + thetaNearBaseline) / 3.0)
    }

    private func scoreDreamy(zDelta: Double, zTheta: Double, zAlpha: Double, zBeta: Double) -> Double {
        let alphaHigh = ramp(zAlpha, low: 0.4, high: 1.6)
        let thetaHigh = ramp(zTheta, low: 0.5, high: 1.8)
        let deltaSupported = ramp(zDelta, low: 0.1, high: 1.2)
        let betaNotHigh = invRamp(zBeta, low: 0.2, high: 1.1)
        return clamp01(
            (0.35 * alphaHigh) +
            (0.30 * thetaHigh) +
            (0.20 * deltaSupported) +
            (0.15 * betaNotHigh)
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
