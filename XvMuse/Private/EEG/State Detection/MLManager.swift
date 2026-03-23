//
//  EEGMLManager.swift
//  XvMuse
//

import Foundation
import CoreML

protocol EEGMLManagerDelegate: AnyObject {
    func didReceiveML(noise: Double, tension: Double, clean: Double)
}

final class EEGMLManager {
    weak var delegate: EEGMLManagerDelegate?

    private let model: MLModel?
    private let mlEveryN: Int = 3
    private var mlCounter: Int = 0

    private var smoothedTensionPct: Double = 0.0
    private let tensionRiseSmoothing: Double = 0.12
    private let tensionFallSmoothing: Double = 0.35

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

            smoothedTensionPct = asymSmooth(
                old: smoothedTensionPct,
                new: tensionScore,
                rise: tensionRiseSmoothing,
                fall: tensionFallSmoothing
            )

            let cleanScore = max(0.0, 100.0 - max(noiseScore, smoothedTensionPct))
            delegate?.didReceiveML(noise: noiseScore, tension: smoothedTensionPct, clean: cleanScore)
        } catch {
            print("❌ EEGMLManager: prediction failed:", error)
        }
    }

    private func usableBins(from spectrum: [Double]) -> [Double] {
        guard spectrum.count >= 3 else { return [] }
        let endExclusive = min(spectrum.count, 48)
        if endExclusive <= 2 { return [] }
        return Array(spectrum[2..<endExclusive])
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private func asymSmooth(old: Double, new: Double, rise: Double, fall: Double) -> Double {
        let factor = new > old ? clamp01(rise) : clamp01(fall)
        return (factor * new) + ((1.0 - factor) * old)
    }
}
