import SwiftUI
import Network
import Combine
import UIKit

// MARK: - App entry

@main
struct GameReadyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Model

enum Status {
    case good, warn, bad

    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad:  return .red
        }
    }

    var icon: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad:  return "xmark.octagon.fill"
        }
    }
}

struct Check: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let status: Status
    let tip: String?
}

// MARK: - Device monitor

final class DeviceMonitor: ObservableObject {
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var batteryLevel: Float = -1
    @Published var batteryState: UIDevice.BatteryState = .unknown
    @Published var freeStorageGB: Double = 0
    @Published var connection = "Checking…"
    @Published var offline = false
    @Published var isExpensive = false
    @Published var isConstrained = false

    private let pathMonitor = NWPathMonitor()
    private var cancellables = Set<AnyCancellable>()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        let nc = NotificationCenter.default
        Publishers.MergeMany(
            nc.publisher(for: ProcessInfo.thermalStateDidChangeNotification),
            nc.publisher(for: .NSProcessInfoPowerStateDidChange),
            nc.publisher(for: UIDevice.batteryLevelDidChangeNotification),
            nc.publisher(for: UIDevice.batteryStateDidChangeNotification),
            nc.publisher(for: UIApplication.didBecomeActiveNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refresh() }
        .store(in: &cancellables)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.offline = path.status != .satisfied
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained
                if path.usesInterfaceType(.wifi) {
                    self.connection = "Wi-Fi"
                } else if path.usesInterfaceType(.cellular) {
                    self.connection = "Cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connection = "Ethernet"
                } else {
                    self.connection = path.status == .satisfied ? "Other" : "No connection"
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "GameReady.NetworkMonitor"))
    }

    deinit { pathMonitor.cancel() }

    func refresh() {
        thermal = ProcessInfo.processInfo.thermalState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
        freeStorageGB = Self.freeStorage()
    }

    private static func freeStorage() -> Double {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            return Double(bytes) / 1_000_000_000
        }
        return 0
    }

    // MARK: Checks

    var checks: [Check] {
        var list: [Check] = []

        // Low Power Mode
        list.append(Check(
            title: "Low Power Mode",
            value: lowPower ? "ON" : "OFF",
            status: lowPower ? .bad : .good,
            tip: lowPower ? "Turn it off in Settings > Battery. It limits the CPU/GPU and caps FPS." : nil
        ))

        // Thermal state
        let thermalText: String
        let thermalStatus: Status
        switch thermal {
        case .nominal:  thermalText = "Normal";   thermalStatus = .good
        case .fair:     thermalText = "Warm";     thermalStatus = .warn
        case .serious:  thermalText = "Hot";      thermalStatus = .bad
        case .critical: thermalText = "Critical"; thermalStatus = .bad
        @unknown default: thermalText = "Unknown"; thermalStatus = .warn
        }
        list.append(Check(
            title: "Temperature",
            value: thermalText,
            status: thermalStatus,
            tip: thermalStatus == .good ? nil :
                "Take the case off, stop charging, move out of the sun, and let the phone cool before playing."
        ))

        // Battery
        let level = batteryLevel >= 0 ? Int(batteryLevel * 100) : -1
        let charging = batteryState == .charging || batteryState == .full
        var batteryStatus: Status = .good
        var batteryTip: String? = nil
        if level >= 0 && level < 20 && !charging {
            batteryStatus = .warn
            batteryTip = "Battery is low. iOS may turn on Low Power Mode and slow the game."
        } else if batteryState == .charging {
            batteryStatus = .warn
            batteryTip = "Charging while gaming adds heat. Unplug if the phone feels warm."
        }
        list.append(Check(
            title: "Battery",
            value: level >= 0 ? "\(level)%" + (charging ? " (charging)" : "") : "Unknown",
            status: batteryStatus,
            tip: batteryTip
        ))

        // Storage
        let storageStatus: Status = freeStorageGB >= 10 ? .good : (freeStorageGB >= 5 ? .warn : .bad)
        list.append(Check(
            title: "Free storage",
            value: String(format: "%.1f GB", freeStorageGB),
            status: storageStatus,
            tip: storageStatus == .good ? nil :
                "Free up space (Settings > General > iPhone Storage). Aim for 10 GB or more."
        ))

        // Network
        var netStatus: Status = .good
        var netTip: String? = nil
        if offline {
            netStatus = .bad
            netTip = "No internet connection."
        } else if isConstrained {
            netStatus = .warn
            netTip = "Low Data Mode is on. Turn it off for smoother online play."
        } else if connection == "Cellular" {
            netStatus = .warn
            netTip = "Cellular is fine if the signal is strong. 5 GHz Wi-Fi near the router is usually steadier."
        }
        list.append(Check(
            title: "Network",
            value: connection,
            status: netStatus,
            tip: netTip
        ))

        return list
    }

    var overall: (title: String, status: Status) {
        let c = checks
        if c.contains(where: { $0.status == .bad }) { return ("Not ready", .bad) }
        if c.contains(where: { $0.status == .warn }) { return ("Almost ready", .warn) }
        return ("Ready to play", .good)
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var monitor = DeviceMonitor()
    @AppStorage("shortcutName") private var shortcutName = "Free Fire Mode"
    @State private var showSetup = false

    var body: some View {
        NavigationView {
            List {
                // Summary
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: monitor.overall.status.icon)
                            .font(.system(size: 36))
                            .foregroundColor(monitor.overall.status.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(monitor.overall.title)
                                .font(.title2.bold())
                            Text("iPhone 12 · Free Fire pre-game check")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                // Checks
                Section(header: Text("Pre-game checklist")) {
                    ForEach(monitor.checks) { check in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: check.status.icon)
                                    .foregroundColor(check.status.color)
                                Text(check.title)
                                Spacer()
                                Text(check.value)
                                    .foregroundColor(.secondary)
                            }
                            if let tip = check.tip {
                                Text(tip)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Game mode
                Section(
                    header: Text("Game Mode"),
                    footer: Text("This runs a Shortcut that quits your other apps, silences notifications, and opens Free Fire. iOS only allows this through Shortcuts, not from inside an app.")
                ) {
                    TextField("Shortcut name", text: $shortcutName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Button {
                        runShortcut(named: shortcutName)
                    } label: {
                        Label("Quit background apps & launch Free Fire", systemImage: "gamecontroller.fill")
                            .font(.headline)
                    }

                    Button {
                        showSetup = true
                    } label: {
                        Label("How to set up the Shortcut", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    Button {
                        monitor.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .navigationTitle("Game Ready")
            .sheet(isPresented: $showSetup) {
                SetupView()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func runShortcut(named name: String) {
        var components = URLComponents(string: "shortcuts://run-shortcut")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("1. Create the Shortcut")) {
                    Text("Open the Shortcuts app, tap +, and name it exactly: Free Fire Mode")
                }
                Section(header: Text("2. Add these actions, in order")) {
                    Text("• Set Low Power Mode → Off")
                    Text("• Set Focus → Do Not Disturb (or a Gaming Focus)")
                    Text("• Quit App → All Apps, with Shortcuts and Game Ready excluded")
                    Text("• Open App → Free Fire")
                }
                Section(
                    header: Text("3. Optional: run it automatically"),
                    footer: Text("If you don't see Quit App, update iOS. On some iOS versions it only closes apps that are in the foreground list, so test it once.")
                ) {
                    Text("Shortcuts > Automation > + > App > Free Fire > Is Opened > Run Shortcut > Free Fire Mode, then turn off Ask Before Running.")
                }
                Section(header: Text("Good to know")) {
                    Text("iOS already freezes background apps, so closing them helps mainly with memory pressure and notifications. Heat, Low Power Mode, and free storage matter more for FPS.")
                }
            }
            .navigationTitle("Shortcut setup")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
