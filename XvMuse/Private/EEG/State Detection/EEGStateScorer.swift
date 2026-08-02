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

    /* Measured from recorded sessions: the coding centroid sits around 12.9 Hz, quiet mind and
     drowsiness around 11.9, eyes-closed meditation around 10.4. The old 12.0-16.5 range only
     reached full scale at a frequency the data never actually visits, so an entire coding session
     scored in the bottom fifth of the gate. */
    var focusCentroidLowHz: Double = 11.5
    var focusCentroidHighHz: Double = 14.5

    //how far alpha sits below theta before it counts as fully suppressed
    var alphaSuppressionLowDb: Double = -6.0
    var alphaSuppressionHighDb: Double = 0.0

    /* How long theta has to keep leading before dreamy believes it. At the 0.25s publish cadence
     0.04 works out to roughly a 6 second memory — long enough to reject isolated blips, short
     enough to follow a genuine slide into drowsiness. */
    var thetaLeadSmoothing: Double = 0.04
    private var smoothedThetaLead: Double = 0.0

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
        smoothedThetaLead = 0.0
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

    func fadeScores(factor: Double, fadeFocus: Bool = true) -> (meditation: Double, focus: Double, dreamy: Double) {
        if fadeFocus {
            focusScore = smoothScore(old: focusScore, new: 0.0, factor: factor)
            focusGate = smoothScore(old: focusGate, new: 0.0, factor: factor)
            focusSupport = smoothScore(old: focusSupport, new: 0.0, factor: factor)
        }

        meditationScore = smoothScore(old: meditationScore, new: 0.0, factor: factor)
        dreamyScore = smoothScore(old: dreamyScore, new: 0.0, factor: factor)

        medGate = smoothScore(old: medGate, new: 0.0, factor: factor)
        medSupport = smoothScore(old: medSupport, new: 0.0, factor: factor)
        dreamyGate = smoothScore(old: dreamyGate, new: 0.0, factor: factor)
        dreamyCredibility = smoothScore(old: dreamyCredibility, new: 0.0, factor: factor)
        dreamySupport = smoothScore(old: dreamySupport, new: 0.0, factor: factor)

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

        /* Alpha suppression replaces the old beta-dominance term, which could never fire.

         Organic signals follow a 1/f slope — big and slow, small and fast — so beta sits 5 to 30 dB
         below delta at all times and is never the loudest band. Checking whether it leads was
         asking a question whose answer is always no, and it was dragging a quarter of the support
         weight to zero on every single frame.

         What engagement actually looks like is the opposite: alpha COLLAPSING. In the coding
         recording alpha ran about 6.6 dB below theta, and frequently went negative outright; in
         eyes-closed meditation it ran 3 dB above. That is classic alpha blocking, and unlike beta
         dominance it is something this hardware can genuinely see.

         It stays in support rather than becoming the gate, because a quiet mind also suppresses
         alpha — the raised centroid is what makes it focus rather than idling. */
        let alphaSuppressed: Double
        if let bands {
            alphaSuppressed = invRamp(
                bands.alpha - bands.theta,
                low: alphaSuppressionLowDb,
                high: alphaSuppressionHighDb
            )
        } else {
            alphaSuppressed = 0.5
        }

        let support = (0.40 * broadEnough) + (0.35 * holdingSteady) + (0.25 * alphaSuppressed)

        focusGate = fastCentroid
        focusSupport = support

        return clamp01(fastCentroid * (0.45 + (0.55 * support)))
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

        /* Theta has to lead for a WHILE, not for an instant.

         Drowsiness is a sustained condition; a one-second theta blip is not falling asleep. In the
         Clear Mind recording theta out-ranked everything else in about a quarter of all frames —
         scattered single frames surrounded by negatives — and each one scored full marks, pushing
         dreamy into the 50s and 60s during an eyes-open resting state.

         Averaged over several seconds the two separate cleanly: Clear Mind sits at about -2.3 dB,
         genuine drowsiness at about +0.3 and holds there. Coding averages -2.3 as well, so this
         cleans up the remaining false positives there too.

         This also repairs a flaw in the stillness gate below. It was added to distinguish real
         drowsiness from theta during hard concentration — but Clear Mind IS still, so the gate
         meant to add skepticism was instead granting full credibility to the one state it cannot
         tell apart from drowsiness. Persistence is what actually separates them. */
        let strongestRival = max(max(bands.delta, bands.alpha), max(bands.beta, bands.gamma))
        smoothedThetaLead += thetaLeadSmoothing * ((bands.theta - strongestRival) - smoothedThetaLead)
        let thetaLeads = ramp(smoothedThetaLead, low: -2.0, high: 1.0)

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
