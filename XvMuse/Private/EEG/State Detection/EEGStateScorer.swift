//
//  EEGStateScorer.swift
//  XvMuse
//

import Foundation

final class EEGStateScorer {
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
