import SwiftUI

// Performance Monitor Singleton
class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    
    @Published var cpuUsage: Double = 0
    @Published var memoryUsageMB: Int = 0
    @Published var isGPUActive: Bool = false
    @Published var cacheHitRate: Double = 0
    @Published var activeCores: Int = 0
    @Published var calculationsPerSecond: Int = 0
    @Published var cacheEntries: Int = 0
    @Published var computeMode: String = "CPU"
    @Published var lastCalcInfo: String = "No calculation yet"

    // FIXED: Default to TRUE so the spinner never appears unless we explicitly ask for it
    @Published var isPreloadComplete: Bool = true
    @Published var preloadProgress: Int = 100
    
    private var timer: Timer?
    private var cacheHits: Int = 0
    private var cacheMisses: Int = 0
    private var calculationCount: Int = 0
    private var lastCalculationReset = Date()
    private var recentCalculations: [Date] = []
    private var isMonitoringStarted = false

    private init() {
        // Don't start monitoring immediately - defer until first calculation
    }

    private func ensureMonitoringStarted() {
        guard !isMonitoringStarted else { return }
        isMonitoringStarted = true
        startMonitoring()
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                self.updateStats()
            }
        }
    }
    
    private func updateStats() {
        // Memory Usage
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        
        if result == KERN_SUCCESS {
            memoryUsageMB = Int(info.resident_size / 1024 / 1024)
        }
        
        // CPU Usage (simplified)
        if let loadAverage = getLoadAverage() {
            cpuUsage = loadAverage * 100
        }
        
        // Cache hit rate
        let totalCacheAccess = cacheHits + cacheMisses
        if totalCacheAccess > 0 {
            cacheHitRate = Double(cacheHits) / Double(totalCacheAccess) * 100
        }
        
        // Calculations per second - use recent calculations
        let now = Date()
        recentCalculations = recentCalculations.filter { now.timeIntervalSince($0) < 1.0 }
        calculationsPerSecond = recentCalculations.count
    }
    
    private func getLoadAverage() -> Double? {
        var loadavg = [Double](repeating: 0.0, count: 3)
        guard getloadavg(&loadavg, 3) == 3 else { return nil }
        return loadavg[0]
    }
    
    // Methods to be called by calculation engines
    func reportCacheHit(_ hit: Bool) {
        if hit {
            cacheHits += 1
        } else {
            cacheMisses += 1
        }
        
        if cacheHits + cacheMisses > 10000 {
            cacheHits = cacheHits / 2
            cacheMisses = cacheMisses / 2
        }
    }
    
    func reportGPUActive(_ active: Bool) {
        DispatchQueue.main.async {
            self.isGPUActive = active
            self.computeMode = active ? "GPU" : "CPU"
        }
    }
    
    func reportCalculation() {
        DispatchQueue.main.async {
            self.ensureMonitoringStarted()
            self.recentCalculations.append(Date())
            if self.recentCalculations.count > 1000 {
                self.recentCalculations.removeFirst(500)
            }
        }
    }
    
    func reportCacheSize(_ size: Int) {
        DispatchQueue.main.async {
            self.cacheEntries = size
        }
    }
    
    func reportActiveCores(_ cores: Int) {
        DispatchQueue.main.async {
            self.activeCores = cores
        }
    }
    
    func reportPreloadProgress(_ progress: Int, isComplete: Bool = false) {
        DispatchQueue.main.async {
            self.preloadProgress = progress
            self.isPreloadComplete = isComplete
        }
    }

    func reportCalcInfo(_ info: String) {
        DispatchQueue.main.async {
            self.lastCalcInfo = info
        }
    }
}
