//
//  EEGMLManager.swift
//  XvMuse
//

import Foundation
import CoreML
import XvDataMapping

protocol EEGMLManagerDelegate: AnyObject {
    func didReceiveMLNoise(noise: Double, clean: Double)
}

/* The model now answers exactly one question: is this signal noise, or is it not?

 It used to also report muscle tension and jaw clenching, but those are far better measured
 directly off the spectrum — EMG has a specific frequency range and shows up as an obvious spike
 above the resting level, which needs no model. Every label other than noise and loose is
 therefore ignored here. Clean is simply the inverse of noise, and it is what opens the gate for
 state scoring. */

final class EEGMLManager {
    weak var delegate: EEGMLManagerDelegate?

    private let model: MLModel?
    private let mlEveryN: Int = 3
    private var mlCounter: Int = 0
    /* The feature names the model was trained on, built once (13 Oct 2026). Each prediction
     used to interpolate all 46 of them again. */
    private static let featureKeyCount = 46
    private let binKeys: [String] = (0..<EEGMLManager.featureKeyCount).map { "bin\($0)" }

    init() {
        do {
            let config = MLModelConfiguration()
            let wrapped = try NoiseTensionClassifier(configuration: config)
            model = wrapped.model
        } catch {
            print("❌ EEGMLManager: Failed to load NoiseTensionClassifier:", error)
            model = nil
        }
    }

    func process(linearSpectrum: [Double]) {
        //the same three guards as before: enough one-hertz bins, the every-third cadence, a model
        guard Self.oneHzCount(forBinCount: linearSpectrum.count) >= 48 else { return }

        mlCounter += 1
        guard mlCounter % mlEveryN == 0 else { return }
        guard model != nil else { return }

        /* DEVICE-LEVEL PREDICTION SKIPPED (13 Oct 2026). XvMuse.didReceiveMLNoise never reads
         the two numbers it is handed: it judges each of the four sensors itself through
         noiseProbability and takes the device score from the best of them. The prediction was
         a fifth of the CoreML cost for a result nobody used, so the callback now fires on the
         same cadence, under the same guards, with a placeholder pair. The one difference: a
         device prediction that would have thrown no longer skips that cycle's callback. */
        delegate?.didReceiveMLNoise(noise: 0.0, clean: 100.0)
    }

    /// Runs the model on a single sensor's spectrum and returns its raw noise score (0–100),
    /// unsmoothed. Used for per-sensor noise localization when device-level noise is high — each
    /// sensor is judged on its own. Does NOT touch the device-level smoothing/delegate path.
    func noiseProbability(forSpectrum spectrum: [Double]) -> Double? {
        let spectrum = Self.oneHzSpectrum(from: spectrum)
        guard spectrum.count >= 48, let model else { return nil }
        do {
            let usable = usableBins(from: spectrum)
            var dict: [String: MLFeatureValue] = [:]
            dict.reserveCapacity(usable.count)
            for (i, value) in usable.enumerated() {
                dict[i < binKeys.count ? binKeys[i] : "bin\(i)"] = MLFeatureValue(double: value)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: dict)
            let out = try model.prediction(from: provider)
            let probs = out.featureValue(for: "labelProbability")?.dictionaryValue as? [String: Double] ?? [:]
            func prob(_ key: String) -> Double {
                let lower = key.lowercased()
                for (label, value) in probs where label.lowercased() == lower { return value }
                return 0.0
            }
            return max(prob("noise"), prob("loose")) * 100.0
        } catch {
            print("❌ EEGMLManager: per-sensor prediction failed:", error)
            return nil
        }
    }

    /* The classifier was trained on 46 features at one-hertz spacing, so it must keep being fed
     exactly that regardless of how finely the spectrum is now sampled.

     Decimating is exact rather than approximate: zero-padding evaluates the same transform on a
     finer grid, so every second bin of the padded spectrum IS the corresponding bin of the
     unpadded one. Taking every other value reconstructs the original 128-bin spectrum bit for
     bit, which is why the model's behaviour is unchanged by the padding. */
    private static func oneHzSpectrum(from spectrum: [Double]) -> [Double] {
        let binsPerHz = Int((Double(XvMuseConstants.EEG_FFT_BINS) / XvMuseConstants.SAMPLING_RATE).rounded())
        guard binsPerHz > 1 else { return spectrum }
        return stride(from: 0, to: spectrum.count, by: binsPerHz).map { spectrum[$0] }
    }

    /* How many bins oneHzSpectrum would return, without building it (13 Oct 2026): the number
     of values stride(from: 0, to: count, by: binsPerHz) yields, which is count / binsPerHz
     rounded up. Lets process() keep its bin-count guard without the allocation. */
    private static func oneHzCount(forBinCount binCount: Int) -> Int {
        let binsPerHz = Int((Double(XvMuseConstants.EEG_FFT_BINS) / XvMuseConstants.SAMPLING_RATE).rounded())
        guard binsPerHz > 1 else { return binCount }
        return (binCount + binsPerHz - 1) / binsPerHz
    }

    private func usableBins(from spectrum: [Double]) -> [Double] {
        guard spectrum.count >= 3 else { return [] }
        let endExclusive = min(spectrum.count, 48)
        if endExclusive <= 2 { return [] }
        return Array(spectrum[2..<endExclusive])
    }

}
