import Foundation
import CPrivateAPIs

final class ThermalSampler {
    struct Sample {
        let socTempC: Double
        let socPeakTempC: Double
        let pCoreTempC: Double
        let eCoreTempC: Double
        let socClusterTempC: Double
        let fanAvailable: Bool
        let fanRPM: Double
        let fanMinRPM: Double
        let fanMaxRPM: Double
        let thermalStateRaw: Int
    }

    func sample() -> Sample {
        let thermal = TBReadThermalInfo()
        let fan = TBReadFanInfo()
        return Sample(
            socTempC: thermal.avgTempC,
            socPeakTempC: thermal.peakTempC,
            pCoreTempC: thermal.pCoreTempC,
            eCoreTempC: thermal.eCoreTempC,
            socClusterTempC: thermal.socClusterTempC,
            fanAvailable: fan.available.boolValue,
            fanRPM: fan.currentRPM,
            fanMinRPM: fan.minRPM,
            fanMaxRPM: fan.maxRPM > 0 ? fan.maxRPM : 7200.0,
            thermalStateRaw: ProcessInfo.processInfo.thermalState.rawValue
        )
    }
}
