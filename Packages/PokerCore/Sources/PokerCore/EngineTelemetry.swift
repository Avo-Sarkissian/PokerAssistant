import Foundation

/// Where the engine reports what it is doing.
///
/// The engine used to call `PerformanceMonitor.shared` directly — an
/// `ObservableObject` in a `import SwiftUI` file — which meant the Monte Carlo
/// simulator could not be compiled, let alone tested, without a UI framework. The
/// engine now speaks to this protocol and the app installs the monitor as the sink.
///
/// Implementations are called from background threads; every one of the monitor's
/// methods already hops to the main queue itself.
/// Only what PokerCore actually reports. The app's monitor has a wider surface than
/// this — notably `reportCalculation()`, which is what starts its sampling timer — but
/// those calls come from `EquityCalculator`, which is still app-side and can call the
/// monitor directly. Adding requirements here that nothing in the engine fires would
/// make every other adopter implement dead methods.
public protocol EngineTelemetrySink: AnyObject {
    func reportActiveCores(_ cores: Int)
    func reportGPUActive(_ active: Bool)
    func reportCalcInfo(_ info: String)
}

/// The installed sink, or nothing at all. Tests leave it unset, which is what makes
/// the engine runnable outside the app.
public enum EngineTelemetry {

    private static let lock = NSLock()
    private static var installed: EngineTelemetrySink?

    public static var sink: EngineTelemetrySink? {
        get {
            lock.lock(); defer { lock.unlock() }
            return installed
        }
        set {
            lock.lock(); defer { lock.unlock() }
            installed = newValue
        }
    }

    static func activeCores(_ cores: Int) { sink?.reportActiveCores(cores) }
    static func gpuActive(_ active: Bool) { sink?.reportGPUActive(active) }
    static func info(_ message: String) { sink?.reportCalcInfo(message) }
}
