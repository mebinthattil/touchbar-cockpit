import Foundation
import CPrivateAPIs

final class ThermalSampler {
    struct Sample {
        let socTempC: Double
        let socPeakTempC: Double
        let fanAvailable: Bool
        let fanRPM: Double
        let fanMaxRPM: Double
    }

    func sample() -> Sample {
        let avg = TBReadSoCTemperature()
        let peak = TBReadSoCPeakTemperature()
        let fan = TBReadFanInfo()
        return Sample(
            socTempC: avg,
            socPeakTempC: peak,
            fanAvailable: fan.available.boolValue,
            fanRPM: fan.currentRPM,
            fanMaxRPM: fan.maxRPM > 0 ? fan.maxRPM : 7200.0
        )
    }
}
