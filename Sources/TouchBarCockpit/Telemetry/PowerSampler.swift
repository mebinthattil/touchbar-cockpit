import Foundation
import IOKit
import CPrivateAPIs

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

    // Cache slow-changing IOKit SmartBattery properties (refreshed every 5s)
    // while reading live 1Hz SMC wattage (PSTR/PDTR/PPBR) every second with zero heap churn.
    private var lastBatteryPoll: CFAbsoluteTime = 0
    private var cachedBatteryPercent: Int = 100
    private var cachedExternal: Bool = true
    private var cachedCharging: Bool = false
    private var cachedMinutes: Int? = nil
    private var cachedAdapterWatts: Int = 0
    private var fallbackSysWatts: Double = 0
    private var fallbackInWatts: Double = 0
    private var fallbackBattWatts: Double = 0

    func sample() -> Sample {
        let now = CFAbsoluteTimeGetCurrent()
        if (now - lastBatteryPoll) >= 5.0 || lastBatteryPoll == 0 {
            refreshSmartBatteryProperties()
            lastBatteryPoll = now
        }

        let smcPower = TBReadSMCPowerInfo()

        var sysDrawWatts: Double = 0
        var chargerInWatts: Double = 0
        var batteryNetWatts: Double = 0

        if smcPower.hasSystemTotal.boolValue && smcPower.systemTotalWatts > 0.05 {
            sysDrawWatts = smcPower.systemTotalWatts
        } else {
            sysDrawWatts = fallbackSysWatts
        }

        if smcPower.hasDCIn.boolValue && cachedExternal {
            chargerInWatts = smcPower.dcInWatts
        } else if cachedExternal {
            chargerInWatts = fallbackInWatts
        }

        if smcPower.hasBatteryPower.boolValue {
            let mag = abs(smcPower.batteryPowerWatts)
            batteryNetWatts = cachedCharging ? mag : (cachedExternal ? (chargerInWatts - sysDrawWatts) : -mag)
        } else {
            batteryNetWatts = fallbackBattWatts
        }

        // If DC-In jumps from 0 -> >1W (charger just plugged in) or drops to 0 (just unplugged),
        // refresh SmartBattery immediately so AC/Battery state updates within 1 second!
        let smcSaysPlugged = smcPower.hasDCIn.boolValue && smcPower.dcInWatts > 0.8
        if smcPower.hasDCIn.boolValue && smcSaysPlugged != cachedExternal {
            refreshSmartBatteryProperties()
            lastBatteryPoll = now
            if !cachedExternal { chargerInWatts = 0 }
        }

        return Sample(
            systemDrawWatts: sysDrawWatts,
            chargerInWatts: chargerInWatts,
            batteryNetWatts: batteryNetWatts,
            adapterMaxWatts: cachedAdapterWatts,
            batteryPercent: cachedBatteryPercent,
            isPluggedIn: cachedExternal,
            isCharging: cachedCharging,
            minutesRemaining: cachedMinutes
        )
    }

    private func refreshSmartBatteryProperties() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = propsRef?.takeRetainedValue() as? [String: Any] else {
            return
        }

        let currentCap = dict["CurrentCapacity"] as? Int ?? 100
        let maxCap = max(1, dict["MaxCapacity"] as? Int ?? 100)
        cachedBatteryPercent = min(100, max(0, (currentCap * 100) / maxCap))
        cachedExternal = dict["ExternalConnected"] as? Bool ?? false
        cachedCharging = dict["IsCharging"] as? Bool ?? false

        if let tte = dict["AvgTimeToEmpty"] as? Int, !cachedExternal, tte > 0, tte < 6000 {
            cachedMinutes = tte
        } else if let ttf = dict["AvgTimeToFull"] as? Int, cachedCharging, ttf > 0, ttf < 6000 {
            cachedMinutes = ttf
        } else {
            cachedMinutes = nil
        }

        if let adapter = dict["AdapterDetails"] as? [String: Any],
           let w = adapter["Watts"] as? Int {
            cachedAdapterWatts = w
        } else {
            cachedAdapterWatts = 0
        }

        var sysW: Double = 0
        var inW: Double = 0
        var battW: Double = 0
        if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
            if let sysLoad = telemetry["SystemLoad"] as? Int, sysLoad > 0 { sysW = Double(sysLoad) / 1000.0 }
            if let sysIn = telemetry["SystemPowerIn"] as? Int, sysIn > 0 { inW = Double(sysIn) / 1000.0 }
            if let battPwr = telemetry["BatteryPower"] as? Int {
                battW = Double(Int64(Int32(truncatingIfNeeded: battPwr))) / 1000.0
            }
        }
        let voltageMV = dict["Voltage"] as? Int ?? 0
        let ampRaw = dict["InstantAmperage"] as? Int64 ?? 0
        if abs(battW) < 0.05 && voltageMV > 0 && abs(ampRaw) > 0 && abs(ampRaw) < 20000 {
            battW = (Double(ampRaw) * Double(voltageMV)) / 1_000_000.0
        }
        if sysW <= 0.05 {
            sysW = (cachedExternal && inW > 0) ? max(0, inW - max(0, battW)) : abs(battW)
        }
        fallbackSysWatts = sysW
        fallbackInWatts = cachedExternal ? inW : 0
        fallbackBattWatts = battW
    }
}
