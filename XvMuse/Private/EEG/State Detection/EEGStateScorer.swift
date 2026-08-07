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

    private(set) var focusBroadEnough: Double = 0.0
    private(set) var focusHoldingSteady: Double = 0.0
    private(set) var focusFastCentroid: Double = 0.0
    private(set) var focusCalmCentroid: Double = 0.0
    private(set) var focusNotAlphaLed: Double = 1.0
    private(set) var meditationAlphaLeadDb: Double = 0.0
    private(set) var meditationAlphaCentroid: Double = 0.0
    private(set) var meditationOrganized: Double = 0.0
    private(set) var meditationHoldingSteady: Double = 0.0
    private(set) var meditationAwakeEnough: Double = 1.0
    private(set) var dreamyThetaLeadDb: Double = 0.0
    private(set) var dreamySmoothedThetaLeadDb: Double = 0.0
    private(set) var dreamyThetaVsFastDb: Double = 0.0
    private(set) var dreamyClearOfFastBands: Double = 0.0
    private(set) var dreamyStillnessPresent: Double = 0.0
    private(set) var dreamyThetaVsDeltaDb: Double = 0.0
    private(set) var dreamyCalmLowEnd: Double = 0.0
    private(set) var dreamyNotRunningFast: Double = 1.0
    private(set) var dreamyLooksLikeRhythm: Double = 1.0
    private(set) var dreamyThetaProminenceDb: Double = 0.0

    //MARK: - Window reference

    /* What the detail window's centroid and spread read when the spectrum has NO structure in it
     at all — just the 1/f background. Supplied by EEGStateAnalyzer, which derives both from
     whichever bins actually survived the filter-response cut.

     Every centroid and spread threshold below is an OFFSET from these, never an absolute Hz.
     That is what makes them survive a change to the detail window. When the window was widened
     from 10-20 to 8-20 the featureless centroid moved from 13.86 Hz to 12.22 Hz — with absolute
     thresholds, every one of them silently became wrong by 1.6 Hz. The 11.5-14.5 focus ramp had
     already drifted that way: on a 10-20 window it scored a completely featureless spectrum at
     0.79, so focus was mostly measuring the window rather than the brain. */
    private var nullCentroidHz: Double = 12.22
    private var nullSpreadHz: Double = 3.27

    func configureWindow(nullCentroidHz: Double, nullSpreadHz: Double) {
        guard nullCentroidHz.isFinite, nullSpreadHz.isFinite, nullSpreadHz > 0 else { return }
        self.nullCentroidHz = nullCentroidHz
        self.nullSpreadHz = nullSpreadHz
    }

    //MARK: - Tunables

    /* Focus has two valid shapes:
       - fast focus: centroid pulled ABOVE the featureless null, i.e. real high-frequency weight
       - calm focus: a steady, broad, slightly-slow centroid, common for a meditator doing
         engaged reading/coding without much high-beta strain.

     Both are offsets in Hz from nullCentroidHz. Fast focus needs the centroid to have actually
     moved up; sitting at the null earns 0.20, not 0.79. */
    var focusTiltOffsetLowHz: Double = -0.5
    var focusTiltOffsetHighHz: Double = 2.0
    var calmFocusTiltOffsetHz: Double = -1.5
    var calmFocusTiltRadiusHz: Double = 1.4

    /* How long theta has to keep leading before dreamy believes it. At the 0.25s publish cadence
     0.04 works out to roughly a 6 second memory — long enough to reject isolated blips, short
     enough to follow a genuine slide into drowsiness. */
    var thetaLeadSmoothing: Double = 0.04
    private var smoothedThetaLead: Double = 0.0

    /* Detrended dB thresholds. Set from the measured distribution on a real late-night session:
     detrended alpha lead ran -8.0 to +2.5 (median -2.7), detrended theta lead -3.8 to +3.6
     (median +0.1). Dreamy's band is deliberately the wider of the two because theta genuinely
     led half the frames in that recording and the score never moved. */
    var meditationAlphaLeadLowDb: Double = -2.0
    var meditationAlphaLeadHighDb: Double = 1.0
    var dreamyThetaLeadLowDb: Double = -1.5
    var dreamyThetaLeadHighDb: Double = 1.5

    //alpha pulls the centroid below the null; how far below still counts as alpha-shaped
    var meditationTiltOffsetHz: Double = -2.0
    var meditationTiltRadiusHz: Double = 3.0

    /* Spread thresholds, also offsets — from nullSpreadHz this time.

     The old absolute pair (0.8...2.6 Hz) could never fire: a featureless 1/f spectrum in a 10 Hz
     window has a spread of about 2.8 Hz, so the ramp topped out BELOW the physical floor and
     `organized` read 0.00 in 79 of 81 frames. Being organized means being narrower than the null,
     which is only expressible as an offset. */
    var organizedOffsetLowHz: Double = -0.8
    var organizedOffsetHighHz: Double = 0.0

    var broadOffsetLowHz: Double = -0.6
    var broadOffsetHighHz: Double = 0.8

    /* Was meditation's low-voltage veto; now observation only, logged as `awake` but not
     multiplied into the score. Relaxed states do not gate each other — see scoreMeditation. */
    var meditationQuietOnset: Double = 25.0
    var meditationQuietFull: Double = 60.0

    /* Theta prominence veto. Below the low value the 4-7 Hz peak is flat enough to be genuine
     diffuse slowing; above the high value it is a discrete ring and almost certainly a loose
     electrode. Derived from 46 bad-fit against 103 good frames — see scoreDreamy. */
    var dreamyProminenceLowDb: Double = 4.0
    var dreamyProminenceHighDb: Double = 7.0

    /* Dreamy's not-fast veto, as an offset from the window's null centroid. */
    var dreamyTiltOffsetOnsetHz: Double = 0.5
    var dreamyTiltOffsetFullHz: Double = 2.0

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
        focusBroadEnough = 0.0
        focusHoldingSteady = 0.0
        focusFastCentroid = 0.0
        focusCalmCentroid = 0.0
        focusNotAlphaLed = 1.0
        meditationAlphaLeadDb = 0.0
        meditationAlphaCentroid = 0.0
        meditationOrganized = 0.0
        meditationHoldingSteady = 0.0
        meditationAwakeEnough = 1.0
        dreamyThetaLeadDb = 0.0
        dreamySmoothedThetaLeadDb = 0.0
        dreamyThetaVsFastDb = 0.0
        dreamyClearOfFastBands = 0.0
        dreamyStillnessPresent = 0.0
        dreamyThetaVsDeltaDb = 0.0
        dreamyCalmLowEnd = 0.0
        dreamyNotRunningFast = 1.0
        dreamyLooksLikeRhythm = 1.0
        dreamyThetaProminenceDb = 0.0
        smoothedThetaLead = 0.0
    }

    func applyStateScores(
        centroidHz: Double,
        spreadHz: Double,
        logPower: Double,
        stability: Double,
        bands: BandBalance?,
        tension: Double,
        thetaProminenceDb: Double,
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
            let newDreamy = scoreDreamy(
                bands,
                centroidHz: centroidHz,
                thetaProminenceDb: thetaProminenceDb
            ) * 100.0 * RelaxedStateGate.damping(forTension: tension)
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

        let tiltOffsetHz = centroidHz - nullCentroidHz
        let spreadOffsetHz = spreadHz - nullSpreadHz

        let fastCentroid = ramp(tiltOffsetHz, low: focusTiltOffsetLowHz, high: focusTiltOffsetHighHz)
        let calmCentroid = centered(
            tiltOffsetHz,
            center: calmFocusTiltOffsetHz,
            radius: calmFocusTiltRadiusHz
        )
        let broadEnough = ramp(spreadOffsetHz, low: broadOffsetLowHz, high: broadOffsetHighHz)
        let holdingSteady = clamp01(stability)

        /* The brake on the calm path: calm focus must not be alpha meditation.

         This used to be `activeNotQuiet`, an inverse ramp on quiet across 55...85. Quiet never
         got above 35 in a whole session, so that term read exactly 1.00 in every single frame —
         a guard that had never once engaged. With no working brake, the calm path was firing on
         real meditation: its centre sits in the alpha range, so the moment alpha pulled the
         centroid down, focus went UP. One frame had tilt at 10.58 Hz, calm at 0.99, focus at 37,
         during eyes-closed practice.

         Alpha leading the detrended spectrum is the thing that actually separates the two states,
         so that is what gates it now. An engaged reader with a flat alpha still qualifies; someone
         sitting in strong alpha does not. */
        let notAlphaLed = bands.map { invRamp($0.alphaLeadDb, low: -1.0, high: 1.0) } ?? 1.0

        let calmFocus = calmCentroid * broadEnough * notAlphaLed
        let focusShape = max(fastCentroid, calmFocus)

        //Keep focus detail-first. Low full-spectrum theta is too noisy to use as support here.
        let support = (0.55 * broadEnough) + (0.45 * holdingSteady)

        focusGate = focusShape
        focusSupport = support
        focusBroadEnough = broadEnough
        focusHoldingSteady = holdingSteady
        focusFastCentroid = fastCentroid
        focusCalmCentroid = calmCentroid
        focusNotAlphaLed = notAlphaLed

        return clamp01(focusShape * (0.45 + (0.55 * support)))
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

        /* Detrended, so this asks "is alpha oscillating above its own background level" rather
         than "is alpha the loudest band", which it can never be — see BandBalance. */
        let alphaLeadDb = bands.alphaLeadDb
        let alphaLeads = ramp(
            alphaLeadDb,
            low: meditationAlphaLeadLowDb,
            high: meditationAlphaLeadHighDb
        )

        let alphaCentroid = centered(
            centroidHz - nullCentroidHz,
            center: meditationTiltOffsetHz,
            radius: meditationTiltRadiusHz
        )
        let organized = invRamp(
            spreadHz - nullSpreadHz,
            low: organizedOffsetLowHz,
            high: organizedOffsetHighHz
        )
        let holdingSteady = clamp01(stability)

        let support = (0.35 * alphaCentroid) + (0.35 * organized) + (0.30 * holdingSteady)

        /* QUIET NO LONGER VETOES THIS. Measured but not multiplied in — same arrangement as
         stillness on dreamy, and for a related reason.

         It was added as a low-voltage veto, to stop sleep onset from reading as meditation. On
         the morning Athena session it zeroed all ~130 frames: quiet published 100 throughout, and
         invRamp(100, 25, 60) is 0, so every score was multiplied by zero. Frames with clear alpha
         lead and strong support — ones that would have scored 63, 73, 88, 90 — all published 0.

         The immediate cause was the calibration being far off (see quietLevelDb), but the design
         is wrong independently of that. Meditation, quiet and dreamy are not competing hypotheses
         about one underlying state; they are separate descriptions that genuinely co-occur and
         trade off through a real session. A relaxed state must not gate another relaxed state,
         because "both at once" is the common case, not a contradiction to be resolved.

         The cost is accepted deliberately: meditation can now score during drowsiness. Dreamy
         will generally be scoring at the same time, and telling those two apart is the consumer's
         job with both numbers in hand — not something to force here by suppressing one of them. */
        let awakeEnough = invRamp(bands.quiet, low: meditationQuietOnset, high: meditationQuietFull)

        medGate = alphaLeads
        medSupport = support
        meditationAlphaLeadDb = alphaLeadDb
        meditationAlphaCentroid = alphaCentroid
        meditationOrganized = organized
        meditationHoldingSteady = holdingSteady
        meditationAwakeEnough = awakeEnough

        return clamp01(alphaLeads * (0.40 + (0.60 * support)))
    }

    /* Dreamy: theta-led, quiet, slow activity. Theta remains full-spectrum upstream, but is
     delayed and artifact-screened so blink/tension pre-roll frames do not count. */
    private func scoreDreamy(
        _ bands: BandBalance,
        centroidHz: Double,
        thetaProminenceDb: Double
    ) -> Double {

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
        let thetaLeadDb = bands.thetaLeadDb
        smoothedThetaLead += thetaLeadSmoothing * (thetaLeadDb - smoothedThetaLead)
        let thetaLeads = ramp(
            smoothedThetaLead,
            low: dreamyThetaLeadLowDb,
            high: dreamyThetaLeadHighDb
        )

        //Broadband noise raises beta too, so theta needs to stand clear of it.
        let thetaVsFastDb = bands.thetaResidual - bands.betaResidual
        let clearOfFastBands = ramp(thetaVsFastDb, low: -1.0, high: 2.0)

        /* Stillness is measured and logged but NO LONGER GATES anything.

         It used to multiply into the score via ramp(quiet, 20, 50). On a real late-night session
         quiet had a median of 0 and cleared 20 in only 11% of frames, so this term alone held
         dreamy at zero for the entire recording regardless of what theta did.

         The deeper problem is that it was pointing the wrong way. Quiet measures absolute low
         amplitude, and a drowsy brain is not low amplitude — it is high-amplitude slow waves. So
         the closer the subject got to sleep onset, the harder this gate pushed dreamy down. Quiet
         is a good measurement doing its own job well; it just cannot also serve as evidence for
         the one state that physically contradicts it.

         Credibility now rests on theta standing clear of beta, plus the artifact screening that
         already invalidates bands around blinks and clenches upstream. */
        let stillnessPresent = ramp(bands.quiet, low: 20.0, high: 50.0)

        //A calm low end. A blink drives delta up and pulls this down.
        let thetaVsDeltaDb = bands.thetaResidual - bands.deltaResidual
        let calmLowEnd = ramp(thetaVsDeltaDb, low: -2.0, high: 2.0)

        /* NOT RUNNING FAST. The one thing theta alone can never do is separate drowsiness from
         concentration — frontal midline theta is a real focus rhythm, and on the sessions measured
         theta lead told the two apart at 0.52, a coin flip. Dreamy was peaking at 61 during focused
         coding as a result.

         What does separate them is where the centroid sits. Drowsy theta rides a slow spectrum;
         Fm theta rides a fast one. Measured: coding centroid +1.7 Hz above the window's null,
         tired +0.1. Vetoing the fast case costs the tired session almost nothing (51 -> 48) and
         removes the coding false positive outright (16 -> 2). */
        let notRunningFast = invRamp(
            centroidHz - nullCentroidHz,
            low: dreamyTiltOffsetOnsetHz,
            high: dreamyTiltOffsetFullHz
        )

        /* NOT A DISCRETE PEAK. The guard that finally catches a badly-seated headset.

         Every other term here compares theta's LEVEL against another band, and a loose electrode
         defeats all of them at once by raising theta harder than anything else. Measured against a
         well-seated session on the same headset: theta +17.5 dB, delta +8.4, alpha +5.7, beta
         +2.0. So `clearOfFastBands` (theta minus beta) and `calmLowEnd` (theta minus delta) both
         open WIDER during the artifact, and blink gating never fires because the worst frames
         score 0-2 on blink.

         Shape separates them where level cannot, and in the opposite direction to intuition: the
         ARTIFACT is the sharp peak, and real drowsy theta is the flat one. Sleep onset is textbook
         low-voltage mixed frequency — everything slows and fades together, so theta rises relative
         to its neighbours without ever forming a bump. A loose electrode rubbing against skin is a
         mechanical system with a characteristic timescale, so it rings.

         Measured across four recordings, 46 bad-fit frames against 103 good, AUC 0.987:

             Muse 2, just put on      median 14.46 dB      dreamy median 64, peaking at 78
             Muse 2, settled           median  2.79 dB      dreamy median 20
             Muse S, just put on       median  7.44 dB
             Muse 2, genuinely tired   median  1.43 dB      dreamy peaking at 87, correctly

         The Muse 2 numbers are the ones that matter: same headset, same person, same recording,
         an 11.7 dB step as the fit settled. That rules out the device and leaves only the fit.

         The peak's LOCATION says the same thing twice over — during bad fit it pins to exactly
         6.00 Hz on both headsets and essentially never moves (stdev 0.19 Hz), while real drowsy
         theta wanders the whole 4-7 Hz band (stdev 1.06 Hz). A rhythm that never changes frequency
         is not a rhythm.

         Ramped 4->7 dB rather than switched: keeps 99% of the genuinely tired frames while
         suppressing 87% of the bad-fit ones. */
        let looksLikeRhythm = invRamp(
            thetaProminenceDb,
            low: dreamyProminenceLowDb,
            high: dreamyProminenceHighDb
        )

        dreamyGate = thetaLeads
        dreamyCredibility = clearOfFastBands
        dreamySupport = calmLowEnd
        dreamyNotRunningFast = notRunningFast
        dreamyLooksLikeRhythm = looksLikeRhythm
        dreamyThetaProminenceDb = thetaProminenceDb
        dreamyThetaLeadDb = thetaLeadDb
        dreamySmoothedThetaLeadDb = smoothedThetaLead
        dreamyThetaVsFastDb = thetaVsFastDb
        dreamyClearOfFastBands = clearOfFastBands
        dreamyStillnessPresent = stillnessPresent
        dreamyThetaVsDeltaDb = thetaVsDeltaDb
        dreamyCalmLowEnd = calmLowEnd

        return clamp01(
            thetaLeads * clearOfFastBands * notRunningFast * looksLikeRhythm
                * (0.50 + (0.50 * calmLowEnd))
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
