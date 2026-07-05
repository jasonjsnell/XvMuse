//
//  EEGMLManager.swift
//  XvMuse
//

import Foundation
import CoreML
import XvDataMapping

protocol EEGMLManagerDelegate: AnyObject {
    func didReceiveML(noise: Double, tension: Double, clean: Double)
}

final class EEGMLManager {
    weak var delegate: EEGMLManagerDelegate?

    private let model: MLModel?
    private let mlEveryN: Int = 3
    private var mlCounter: Int = 0

    private let tensionSmoother = XvAttackReleaseSmoother(
        attack: 0.32,
        release: 0.35
    )

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
        guard linearSpectrum.count == 128 else { return }

        mlCounter += 1
        guard mlCounter % mlEveryN == 0 else { return }
        guard let model else { return }

        do {
            let usable = usableBins(from: linearSpectrum)
            var dict: [String: MLFeatureValue] = [:]
            dict.reserveCapacity(usable.count)

            for (i, value) in usable.enumerated() {
                dict["bin\(i)"] = MLFeatureValue(double: value)
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: dict)
            let out = try model.prediction(from: provider)
            let probs = out.featureValue(for: "labelProbability")?.dictionaryValue as? [String: Double] ?? [:]

            func prob(_ key: String) -> Double {
                let lower = key.lowercased()
                for (label, value) in probs where label.lowercased() == lower {
                    return value
                }
                return 0.0
            }

            let noiseScore = max(prob("noise"), prob("loose")) * 100.0

            let tensionScore = probs.reduce(0.0) { current, item in
                let normalized = item.key.lowercased()
                guard normalized != "clean", normalized != "noise", normalized != "loose" else {
                    return current
                }
                return max(current, item.value * 100.0)
            }

            let smoothedTensionPct = tensionSmoother.update(with: tensionScore)

            let cleanScore = max(0.0, 100.0 - max(noiseScore, smoothedTensionPct))
            delegate?.didReceiveML(noise: noiseScore, tension: smoothedTensionPct, clean: cleanScore)
        } catch {
            print("❌ EEGMLManager: prediction failed:", error)
        }
    }

    /// Runs the model on a single sensor's spectrum and returns its raw noise score (0–100),
    /// unsmoothed. Used for per-sensor noise localization when device-level noise is high — each
    /// sensor is judged on its own. Does NOT touch the device-level smoothing/delegate path.
    func noiseProbability(forSpectrum spectrum: [Double]) -> Double? {
        guard spectrum.count == 128, let model else { return nil }
        do {
            let usable = usableBins(from: spectrum)
            var dict: [String: MLFeatureValue] = [:]
            dict.reserveCapacity(usable.count)
            for (i, value) in usable.enumerated() {
                dict["bin\(i)"] = MLFeatureValue(double: value)
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

    private func usableBins(from spectrum: [Double]) -> [Double] {
        guard spectrum.count >= 3 else { return [] }
        let endExclusive = min(spectrum.count, 48)
        if endExclusive <= 2 { return [] }
        return Array(spectrum[2..<endExclusive])
    }

}
