import SwiftUI

struct PerformanceMonitorView: View {
    @StateObject private var monitor = PerformanceMonitor.shared
    @State private var showDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Preloading indicator
            if !monitor.isPreloadComplete {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading poker data... \(monitor.preloadProgress)%")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
            
            // Compact view
            HStack(spacing: 12) {
                // CPU Usage
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text("\(Int(monitor.cpuUsage))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(cpuColor)
                }
                
                // Memory Usage
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                    Text("\(monitor.memoryUsageMB)MB")
                        .font(.caption2.monospacedDigit())
                }
                
                // GPU Active
                if monitor.isGPUActive {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("GPU")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
                
                // Cache Hit Rate
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                    Text("\(Int(monitor.cacheHitRate))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(cacheColor)
                }
                
                Spacer()
                
                Button(action: { showDetails.toggle() }) {
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .cornerRadius(6)
            
            // Detailed view
            if showDetails {
                VStack(alignment: .leading, spacing: 8) {
                    // Cores visualization
                    HStack(spacing: 4) {
                        ForEach(0..<6) { core in
                            CoreIndicator(active: core < monitor.activeCores)
                        }
                        Text("\(monitor.activeCores)/6 cores")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Performance stats
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                        GridRow {
                            Text("Calculations/sec:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(monitor.calculationsPerSecond > 0 ? "\(monitor.calculationsPerSecond)" : "—")
                                .font(.caption2.monospacedDigit())
                        }
                        
                        GridRow {
                            Text("Cache size:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(monitor.cacheEntries / 1000)K entries")
                                .font(.caption2.monospacedDigit())
                        }
                        
                        GridRow {
                            Text("Compute mode:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(monitor.computeMode)
                                .font(.caption2)
                                .foregroundColor(monitor.isGPUActive ? .green : .blue)
                        }

                        GridRow {
                            Text("Last calc:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(MetalCompute.lastDebugInfo)
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }

                        if monitor.isPreloadComplete {
                            GridRow {
                                Text("Data loaded:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("✓ Ready")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDetails)
        .animation(.easeInOut(duration: 0.2), value: monitor.isPreloadComplete)
    }
    
    private var cpuColor: Color {
        if monitor.cpuUsage > 400 { return .red }
        if monitor.cpuUsage > 200 { return .orange }
        return .green
    }
    
    private var cacheColor: Color {
        if monitor.cacheHitRate > 80 { return .green }
        if monitor.cacheHitRate > 50 { return .orange }
        return .red
    }
}

struct CoreIndicator: View {
    let active: Bool
    
    var body: some View {
        Circle()
            .fill(active ? Color.green : Color.gray.opacity(0.3))
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.gray.opacity(0.5), lineWidth: 0.5)
            )
    }
}
