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
        let thermal = TBReadThermalInfo()
        let fan = TBReadFanInfo()
        return Sample(
            socTempC: thermal.avgTempC,
            socPeakTempC: thermal.peakTempC,
            fanAvailable: fan.available.boolValue,
            fanRPM: fan.currentRPM,
            fanMaxRPM: fan.maxRPM > 0 ? fan.maxRPM : 7200.0
        )
    }
}
