import Foundation

struct SystemMetrics {
    // CPU
    var cpuTotal: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var loadAvg1m: Double = 0
    var coreLoads: [Double] = []
    var eCoreCount: Int = 4
    var cpuHistory: [Double] = Array(repeating: 0, count: 48)

    // Memory
    var memUsedGB: Double = 0
    var memTotalGB: Double = 16
    var memAppGB: Double = 0
    var memWiredGB: Double = 0
    var memCompressedGB: Double = 0
    var memCachedGB: Double = 0
    var memActiveFrac: Double = 0
    var memWiredFrac: Double = 0
    var memCompressedFrac: Double = 0
    var swapUsedGB: Double = 0
    var swapTotalGB: Double = 0
    var memHistory: [Double] = Array(repeating: 0, count: 48)

    // Thermal & Fan
    var socTempC: Double = -1
    var socPeakTempC: Double = -1
    var pCoreTempC: Double = -1
    var eCoreTempC: Double = -1
    var socClusterTempC: Double = -1
    var fanRPM: Double = 0
    var fanMinRPM: Double = 0
    var fanMaxRPM: Double = 7200
    var fanAvailable: Bool = false
    var thermalStateRaw: Int = 0
    var tempHistory: [Double] = Array(repeating: 0, count: 48)

    // Power & Battery
    var powerWatts: Double = 0
    var chargerInWatts: Double = 0
    var batteryNetWatts: Double = 0
    var adapterMaxWatts: Int = 0
    var batteryPercent: Int = 100
    var batteryHealthPct: Int = 0
    var batteryCycleCount: Int = 0
    var batteryTempC: Double = -1
    var batteryVoltageV: Double = 0
    var isPluggedIn: Bool = false
    var isCharging: Bool = false
    var minutesRemaining: Int? = nil
    var powerHistory: [Double] = Array(repeating: 0, count: 48)
    var chargerInHistory: [Double] = Array(repeating: 0, count: 48)

    // Network & Privacy
    var netDownBps: Double = 0
    var netUpBps: Double = 0
    var netDownHistory: [Double] = Array(repeating: 0, count: 36)
    var netUpHistory: [Double] = Array(repeating: 0, count: 36)
    var primaryInterface: String = ""
    var localIPv4: String = ""
    var sessionDownBytes: UInt64 = 0
    var sessionUpBytes: UInt64 = 0
    var tailscaleActive: Bool = false
    var vpnActive: Bool = false
    var proxyActive: Bool = false

    // Status
    var keepAwakeActive: Bool = false
    var timestamp: Date = Date()
}
