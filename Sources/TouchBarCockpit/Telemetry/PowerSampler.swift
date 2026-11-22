import Foundation
import IOKit

final class PowerSampler {
    struct Sample {
        let systemDrawWatts: Double
        let chargerInWatts: Double
        let batteryNetWatts: Double
        let adapterMaxWatts: Int
        let batteryPercent: Int
        let isPluggedIn: Bool
        let isCharging: Bool
        let minutesRemaining: Int?
    }

    func sample() -> Sample {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return Sample(systemDrawWatts: 0, chargerInWatts: 0, batteryNetWatts: 0, adapterMaxWatts: 0, batteryPercent: 100, isPluggedIn: true, isCharging: false, minutesRemaining: nil)
        }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = propsRef?.takeRetainedValue() as? [String: Any] else {
            return Sample(systemDrawWatts: 0, chargerInWatts: 0, batteryNetWatts: 0, adapterMaxWatts: 0, batteryPercent: 100, isPluggedIn: true, isCharging: false, minutesRemaining: nil)
        }

        let currentCap = dict["CurrentCapacity"] as? Int ?? 100
        let maxCap = max(1, dict["MaxCapacity"] as? Int ?? 100)
        let pct = min(100, max(0, (currentCap * 100) / maxCap))

        let external = dict["ExternalConnected"] as? Bool ?? false
        let charging = dict["IsCharging"] as? Bool ?? false

        var minutes: Int? = nil
        if let tte = dict["AvgTimeToEmpty"] as? Int, !external, tte > 0, tte < 6000 {
            minutes = tte
        } else if let ttf = dict["AvgTimeToFull"] as? Int, charging, ttf > 0, ttf < 6000 {
            minutes = ttf
        }

        var adapterMaxWatts = 0
        if let adapter = dict["AdapterDetails"] as? [String: Any],
           let w = adapter["Watts"] as? Int {
            adapterMaxWatts = w
        }

        // Read both live SystemLoad (power system is drawing) and SystemPowerIn (power pulled from charger)
        var sysDrawWatts: Double = 0
        var chargerInWatts: Double = 0
        var batteryNetWatts: Double = 0

        if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
            if let sysLoad = telemetry["SystemLoad"] as? Int, sysLoad > 0 {
                sysDrawWatts = Double(sysLoad) / 1000.0
            }
            if let sysIn = telemetry["SystemPowerIn"] as? Int, sysIn > 0 {
                chargerInWatts = Double(sysIn) / 1000.0
            }
            if let battPwr = telemetry["BatteryPower"] as? Int {
                // Signed integer in mW (positive = charging battery, negative = discharging)
                let signedPwr = Int64(Int32(truncatingIfNeeded: battPwr))
                batteryNetWatts = Double(signedPwr) / 1000.0
            }
        }

        // Fallback if SystemLoad is unavailable on battery
        let voltageMV = dict["Voltage"] as? Int ?? 0
        let ampRaw = dict["InstantAmperage"] as? Int64 ?? 0
        let ampMA = Double(ampRaw)
        if abs(batteryNetWatts) < 0.05 && voltageMV > 0 && abs(ampMA) > 0 && abs(ampMA) < 20000 {
            batteryNetWatts = (ampMA * Double(voltageMV)) / 1_000_000.0
        }
        if sysDrawWatts <= 0.05 {
            if external && chargerInWatts > 0 {
                sysDrawWatts = max(0, chargerInWatts - max(0, batteryNetWatts))
            } else {
                sysDrawWatts = abs(batteryNetWatts)
            }
        }
        if !external {
            chargerInWatts = 0
        }

        return Sample(
            systemDrawWatts: sysDrawWatts,
            chargerInWatts: chargerInWatts,
            batteryNetWatts: batteryNetWatts,
            adapterMaxWatts: adapterMaxWatts,
            batteryPercent: pct,
            isPluggedIn: external,
            isCharging: charging,
            minutesRemaining: minutes
        )
    }
}
