import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

@MainActor
final class AppViewModel: ObservableObject {
    struct BugReportDraft {
        let title: String
        let systemInfo: String
        let diagnosticsFileName: String
        let diagnosticsData: Data
    }

    private struct NetworkInterfaceInfo {
        enum Kind: String {
            case wifi = "Wi-Fi"
            case ethernet = "Ethernet"
        }

        let device: String
        let hardwarePort: String
        let networkService: String
        let kind: Kind
    }

    private struct MACSpoofResult {
        let summary: String
        let hasWarning: Bool
        let wasSkipped: Bool
    }

    private enum Constants {
        static let errorDomain = "1132Fixer"
        static let bashPath = ShellCommands.bashPath
        static let osascriptPath = ShellCommands.osascriptPath
    }

    private final class LockedDataBuffer {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let copy = data
            lock.unlock()
            return copy
        }
    }

    private static let logTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
    private static let bugTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()
    private static let diagnosticsFileName = "1132Fixer-diagnostics.txt"

    enum WorkflowState: Equatable {
        case idle
        case preflight
        case closingZoom
        case spoofingMAC
        case checkingNetwork
        case backingUpState
        case clearingState
        case flushingDNS
        case stoppingUpdaters
        case checkingMediaAccess
        case launchingZoom
        case completed
        case failed(String)
        case canceled
    }

    struct StepResult: Identifiable, Equatable {
        let id: String
        let name: String
        let succeeded: Bool
        let detail: String?
    }

    struct PreflightInfo: Equatable {
        enum Status: Equatable {
            case loading
            case ready
            case error(String)
        }

        struct Check: Identifiable, Equatable {
            let id: String
            let label: String
            let value: String
            let isWarning: Bool
        }

        var status: Status = .loading
        var checks: [Check] = []
    }

    @Published var logs: [String] = []
    struct WorkflowProgress: Equatable {
        struct Step: Identifiable, Equatable {
            let id: String
            let name: String
            var state: StepState
        }
        enum StepState: Equatable {
            case pending, running, succeeded, failed, skipped
        }
        var steps: [Step] = []
        var currentStepIndex: Int = 0
    }

    @Published var isRunning = false
    @Published var workflowState: WorkflowState = .idle
    @Published var preflight = PreflightInfo()
    @Published var lastRunResults: [StepResult]?
    @Published var workflowProgress: WorkflowProgress?
    private var runningTask: Task<Void, Never>?
    private var currentProcess: Process?
    private let stopZoomCommand = ShellCommands.stopZoom
    private let stopZoomUpdatersCommand = ShellCommands.stopZoomUpdaters
    private let refreshDNSAppleScript = ShellCommands.refreshDNSAppleScript

    /// The `zoom.us.app` bundle path currently in effect. `nil` means the default
    /// `/Applications` location; a non-nil value is a user-selected location.
    @Published var customZoomAppPath: String? = ZoomLocation.customAppPath

    /// The effective Zoom executable path (default or user-selected).
    private var zoomBinaryPath: String { ZoomLocation.binaryPath }

    /// The effective `zoom.us.app` bundle path (default or user-selected).
    var zoomAppPath: String { ZoomLocation.appPath }

    func startZoom() {
        lastRunResults = nil
        initProgress(steps: [
            ("closeZoom", "Close Zoom"),
            ("network", ShellCommands.isMacSpoofingDisabledForCurrentOS() ? "Network Check" : "MAC Spoof & Network"),
            ("backup", "Backup State"),
            ("resetData", "Clear Local State"),
            ("dns", "DNS Flush"),
            ("updaters", "Stop Updaters"),
            ("mediaAccess", "Camera & Mic"),
            ("launch", "Launch Zoom"),
        ])
        runTask("Start Zoom") {
            var results: [StepResult] = []

            // 1. Close Zoom
            self.workflowState = .closingZoom
            self.markStepRunning("closeZoom")
            self.appendLog("Step: Close Zoom if it is running")
            do {
                let output = try await self.runProcess(
                    stepName: "Close Zoom",
                    executable: Constants.bashPath,
                    arguments: ["-c", self.stopZoomCommand]
                )
                self.markStepDone("closeZoom", succeeded: true)
                results.append(.init(id: "closeZoom", name: "Close Zoom", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("closeZoom", succeeded: false)
                results.append(.init(id: "closeZoom", name: "Close Zoom", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 2. Network handling
            self.workflowState = ShellCommands.isMacSpoofingDisabledForCurrentOS() ? .checkingNetwork : .spoofingMAC
            self.markStepRunning("network")
            self.appendLog(ShellCommands.isMacSpoofingDisabledForCurrentOS()
                ? "Step: Check active network; MAC spoofing is disabled on macOS 14+"
                : "Step: Spoof MAC and reconnect active network (admin prompt expected)")
            let macSpoofResult: MACSpoofResult
            do {
                macSpoofResult = try await self.spoofMACAndReconnectActiveInterface()
                if macSpoofResult.wasSkipped {
                    self.markStepSkipped("network")
                } else {
                    self.markStepDone("network", succeeded: !macSpoofResult.hasWarning)
                }
                results.append(.init(
                    id: "network",
                    name: ShellCommands.isMacSpoofingDisabledForCurrentOS() ? "Network Check" : "MAC Spoof & Network",
                    succeeded: !macSpoofResult.hasWarning,
                    detail: macSpoofResult.summary
                ))
            } catch {
                macSpoofResult = MACSpoofResult(summary: "Network step skipped: \(error.localizedDescription)", hasWarning: true, wasSkipped: true)
                self.markStepDone("network", succeeded: false)
                results.append(.init(id: "network", name: "Network Check", succeeded: false, detail: error.localizedDescription))
            }

            // 3. Backup Zoom state
            self.workflowState = .backingUpState
            self.markStepRunning("backup")
            self.appendLog("Step: Backup Zoom local state")
            do {
                let output = try await self.runProcess(
                    stepName: "Backup Zoom state",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeBackupZoomDataCommand()],
                    timeout: 30
                )
                let backupPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.markStepDone("backup", succeeded: true)
                results.append(.init(id: "backup", name: "Backup State", succeeded: true, detail: backupPath.isEmpty ? nil : "Saved to \(backupPath)"))
            } catch {
                self.markStepDone("backup", succeeded: false)
                results.append(.init(id: "backup", name: "Backup State", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: Backup failed, continuing anyway: \(error.localizedDescription)")
            }

            // 4. Reset Zoom data
            self.workflowState = .clearingState
            self.markStepRunning("resetData")
            self.appendLog("Step: Reset Zoom data")
            do {
                let resetCommand = ShellCommands.makeResetZoomDataCommand(homeDirectory: NSHomeDirectory())
                let resetScript = ShellCommands.appleScriptDoShellScript(resetCommand, administratorPrivileges: true)
                let output = try await self.runProcess(
                    stepName: "Reset Zoom data",
                    executable: Constants.osascriptPath,
                    arguments: ["-e", resetScript]
                )
                self.markStepDone("resetData", succeeded: true)
                results.append(.init(id: "resetData", name: "Clear Local State", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("resetData", succeeded: false)
                results.append(.init(id: "resetData", name: "Clear Local State", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 5. DNS flush
            self.workflowState = .flushingDNS
            self.markStepRunning("dns")
            self.appendLog("Step: Refresh DNS cache (admin prompt may appear)")
            do {
                let output = try await self.runProcess(
                    stepName: "Refresh DNS cache",
                    executable: Constants.osascriptPath,
                    arguments: ["-e", self.refreshDNSAppleScript]
                )
                self.markStepDone("dns", succeeded: true)
                results.append(.init(id: "dns", name: "DNS Flush", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("dns", succeeded: false)
                results.append(.init(id: "dns", name: "DNS Flush", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 6. Stop updaters
            self.workflowState = .stoppingUpdaters
            self.markStepRunning("updaters")
            self.appendLog("Step: Stop Zoom updaters")
            do {
                let output = try await self.runProcess(
                    stepName: "Stop Zoom updaters",
                    executable: Constants.bashPath,
                    arguments: ["-c", self.stopZoomUpdatersCommand]
                )
                self.markStepDone("updaters", succeeded: true)
                results.append(.init(id: "updaters", name: "Stop Updaters", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("updaters", succeeded: false)
                results.append(.init(id: "updaters", name: "Stop Updaters", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 7. Ensure camera and microphone access before the sandboxed launch.
            // Zoom runs under sandbox-exec, so macOS attributes Zoom's camera/mic
            // TCC requests to this app (the launcher). This app must therefore hold
            // the grants for Zoom to see the camera/mic. Denial is non-fatal: Zoom
            // still launches so the 1132 fix proceeds; only A/V is affected.
            self.workflowState = .checkingMediaAccess
            self.markStepRunning("mediaAccess")
            self.appendLog("Step: Check camera and microphone access")
            do {
                let detail = try await self.ensureMediaAccessForSandboxedZoom()
                self.markStepDone("mediaAccess", succeeded: true)
                results.append(.init(id: "mediaAccess", name: "Camera & Mic", succeeded: true, detail: detail))
            } catch {
                self.markStepDone("mediaAccess", succeeded: false)
                results.append(.init(id: "mediaAccess", name: "Camera & Mic", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 8. Launch Zoom
            self.workflowState = .launchingZoom
            self.markStepRunning("launch")
            self.appendLog("Step: Launch Zoom")
            do {
                let output = try await self.runProcess(
                    stepName: "Launch Zoom",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: self.zoomBinaryPath)],
                    timeout: 120
                )
                self.markStepDone("launch", succeeded: true)
                results.append(.init(id: "launch", name: "Launch Zoom", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("launch", succeeded: false)
                results.append(.init(id: "launch", name: "Launch Zoom", succeeded: false, detail: error.localizedDescription))
                throw error // Launch failure is fatal
            }

            self.lastRunResults = results

            let allSucceeded = results.allSatisfy(\.succeeded)
            let failedSteps = results.filter { !$0.succeeded }.map(\.name)
            let summaryParts = results.map { step in
                "\(step.succeeded ? "OK" : "WARN") \(step.name)\(step.detail.map { ": \($0.prefix(80))" } ?? "")"
            }

            let header = allSucceeded
                ? "All steps completed successfully."
                : "Completed with warnings: \(failedSteps.joined(separator: ", "))"

            return header + "\n" + summaryParts
                .joined(separator: "\n")
        }
    }

    private func initProgress(steps: [(id: String, name: String)]) {
        workflowProgress = WorkflowProgress(
            steps: steps.map { .init(id: $0.id, name: $0.name, state: .pending) },
            currentStepIndex: 0
        )
    }

    private func markStepRunning(_ id: String) {
        guard var progress = workflowProgress,
              let idx = progress.steps.firstIndex(where: { $0.id == id }) else { return }
        progress.steps[idx].state = .running
        progress.currentStepIndex = idx
        workflowProgress = progress
    }

    private func markStepDone(_ id: String, succeeded: Bool) {
        guard var progress = workflowProgress,
              let idx = progress.steps.firstIndex(where: { $0.id == id }) else { return }
        progress.steps[idx].state = succeeded ? .succeeded : .failed
        workflowProgress = progress
    }

    private func markStepSkipped(_ id: String) {
        guard var progress = workflowProgress,
              let idx = progress.steps.firstIndex(where: { $0.id == id }) else { return }
        progress.steps[idx].state = .skipped
        workflowProgress = progress
    }

    func cancelWorkflow() {
        runningTask?.cancel()
        currentProcess?.terminate()
        workflowState = .canceled
        appendLog("Workflow canceled by user.")
        isRunning = false
    }

    func dryRun() {
        lastRunResults = nil
        workflowProgress = nil
        runTask("Dry Run") {
            var results: [String] = []

            // Check macOS version
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            results.append("macOS: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")

            // Check architecture
            let arch = ShellCommands.machineArchitecture()
            results.append("Architecture: \(arch == "arm64" ? "Apple Silicon" : (arch == "x86_64" ? "Intel" : arch))")

            // Check Zoom
            let zoomInstalled = FileManager.default.fileExists(atPath: self.zoomBinaryPath)
            results.append("Zoom binary: \(zoomInstalled ? "Found" : "NOT FOUND") at \(self.zoomBinaryPath)")
            if self.customZoomAppPath != nil {
                results.append("Zoom location: Custom (\(self.zoomAppPath))")
            }

            let zoomRunning = (try? await self.runProcess(
                stepName: "Check Zoom process",
                executable: Constants.bashPath,
                arguments: ["-c", "/usr/bin/pgrep -x \"zoom.us\" >/dev/null 2>&1 && echo running || echo stopped"]
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            results.append("Zoom process: \(zoomRunning)")

            // Check network interface
            do {
                let routeOutput = try await self.runProcess(
                    stepName: "Detect interface",
                    executable: Constants.bashPath,
                    arguments: ["-c", "/sbin/route -n get default 2>/dev/null"]
                )
                let device = try ShellCommands.parseDefaultRouteInterface(from: routeOutput)

                let portsOutput = try await self.runProcess(
                    stepName: "Hardware ports",
                    executable: Constants.bashPath,
                    arguments: ["-c", "/usr/sbin/networksetup -listallhardwareports"]
                )
                let portMap = ShellCommands.parseHardwarePorts(from: portsOutput)
                let portName = portMap[device] ?? "Unknown"
                results.append("Active interface: \(portName) (\(device))")

                if let kind = try? ShellCommands.classifySupportedInterface(hardwarePortName: portName) {
                    results.append("Interface type: \(kind.rawValue)")
                    if ShellCommands.isMacSpoofingDisabledForCurrentOS() {
                        results.append("MAC spoofing: Disabled on macOS 14+")
                    } else if kind == .wifi && ShellCommands.isMacSpoofingBlockedOnWiFi() {
                        results.append("MAC spoofing: BLOCKED (Apple Silicon + macOS 14+)")
                    } else {
                        results.append("MAC spoofing: Available")
                    }
                }
            } catch {
                results.append("Network: \(error.localizedDescription)")
            }

            results.append("")
            results.append("Dry run complete. No changes were made to your system.")
            return results.joined(separator: "\n")
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func runPreflight() {
        preflight = PreflightInfo(status: .loading, checks: [])
        Task {
            var checks: [PreflightInfo.Check] = []

            // macOS version
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            let osString = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
            checks.append(.init(id: "os", label: "macOS", value: osString, isWarning: osVersion.majorVersion < 13))

            // Architecture
            let arch = ShellCommands.machineArchitecture()
            let archLabel = arch == "arm64" ? "Apple Silicon" : (arch == "x86_64" ? "Intel" : arch)
            checks.append(.init(id: "arch", label: "Architecture", value: archLabel, isWarning: false))

            // Zoom installed
            let zoomInstalled = FileManager.default.fileExists(atPath: zoomBinaryPath)
            let zoomValue: String
            if zoomInstalled {
                zoomValue = customZoomAppPath != nil ? "Installed (custom location)" : "Installed"
            } else {
                zoomValue = "Not found"
            }
            checks.append(.init(id: "zoom", label: "Zoom App", value: zoomValue, isWarning: !zoomInstalled))

            // Active interface & VPN
            do {
                let routeOutput = try await runProcess(
                    stepName: "Preflight: detect interface",
                    executable: Constants.bashPath,
                    arguments: ["-c", "/sbin/route -n get default 2>/dev/null"]
                )
                let device = try ShellCommands.parseDefaultRouteInterface(from: routeOutput)

                let portsOutput = try await runProcess(
                    stepName: "Preflight: hardware ports",
                    executable: Constants.bashPath,
                    arguments: ["-c", "/usr/sbin/networksetup -listallhardwareports"]
                )
                let portMap = ShellCommands.parseHardwarePorts(from: portsOutput)
                let portName = portMap[device] ?? "Unknown"

                checks.append(.init(id: "iface", label: "Active Interface", value: "\(portName) (\(device))", isWarning: false))
                checks.append(.init(id: "vpn", label: "VPN", value: "Not detected", isWarning: false))
            } catch {
                let msg = error.localizedDescription
                if msg.contains("VPN detected") {
                    checks.append(.init(id: "vpn", label: "VPN", value: "Active (turn off before running)", isWarning: true))
                } else {
                    checks.append(.init(id: "iface", label: "Active Interface", value: "Could not detect", isWarning: true))
                }
            }

            // Admin prompts expected (DNS flush needs admin; MAC spoofing on supported macOS also needs admin)
            checks.append(.init(id: "admin", label: "Admin Prompts", value: "Expected", isWarning: false))

            // MAC spoofing availability
            if ShellCommands.isMacSpoofingDisabledForCurrentOS() {
                checks.append(.init(id: "macspoof", label: "MAC Spoofing", value: "Disabled on macOS 14+", isWarning: false))
            } else if ShellCommands.isMacSpoofingBlockedOnWiFi() {
                checks.append(.init(id: "macspoof", label: "MAC Spoofing", value: "Blocked on Wi-Fi (Apple Silicon + macOS 14+)", isWarning: true))
            }

            preflight = PreflightInfo(status: .ready, checks: checks)
        }
    }

    func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logs.joined(separator: "\n"), forType: .string)
    }

    func logMessage(_ text: String) {
        appendLog(text)
    }

    func exportDiagnostics(appVersion: String) {
        let diagnostics = makeDiagnosticsExport(appVersion: appVersion)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = diagnostics.fileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try diagnostics.content.write(to: url, atomically: true, encoding: .utf8)
            appendLog("Diagnostics exported to \(url.lastPathComponent)")
        } catch {
            appendLog("Failed to export diagnostics: \(error.localizedDescription)")
        }
    }

    func makeBugReportDraft(appVersion: String) -> BugReportDraft {
        let now = Date()
        let title = "Bug Report \(Self.bugTitleFormatter.string(from: now))"
        let timestamp = Self.logTimestampFormatter.string(from: now)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let architecture = ShellCommands.machineArchitecture()
        let lastStatus = inferLastActionStatus()
        let systemInfo = """
App version: \(appVersion)
OS: \(osVersion)
Architecture: \(architecture)
Timestamp: \(timestamp)
Last action status: \(lastStatus)
"""
        let diagnostics = makeDiagnosticsExport(appVersion: appVersion)
        return BugReportDraft(
            title: title,
            systemInfo: systemInfo,
            diagnosticsFileName: diagnostics.fileName,
            diagnosticsData: Data(diagnostics.content.utf8)
        )
    }

    private func makeDiagnosticsExport(appVersion: String, maxLogLines: Int? = nil) -> (fileName: String, content: String) {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let arch = ShellCommands.machineArchitecture()
        let lastStatus = inferLastActionStatus()
        let timestamp = Self.logTimestampFormatter.string(from: Date())

        var lines: [String] = []
        lines.append("1132 Fixer Diagnostics Report")
        lines.append("Generated: \(timestamp)")
        lines.append("App version: \(appVersion)")
        lines.append("OS: \(osVersion)")
        lines.append("Architecture: \(arch)")
        lines.append("Last action status: \(lastStatus)")
        lines.append("")
        lines.append(contentsOf: DiagnosticsCollector.makeSnapshot())
        lines.append("")

        if let results = lastRunResults {
            lines.append("--- Step Results ---")
            for step in results {
                let mark = step.succeeded ? "OK" : "WARN"
                lines.append("[\(mark)] \(step.name)\(step.detail.map { " — \($0)" } ?? "")")
            }
            lines.append("")
        }

        if !preflight.checks.isEmpty {
            lines.append("--- Preflight Checks ---")
            for check in preflight.checks {
                let mark = check.isWarning ? "!" : "+"
                lines.append("[\(mark)] \(check.label): \(check.value)")
            }
            lines.append("")
        }

        let logLines: [String]
        if let maxLogLines {
            logLines = Array(logs.suffix(maxLogLines))
        } else {
            logLines = logs
        }

        lines.append("--- Activity Log (\(logLines.count) entries) ---")
        lines.append(contentsOf: logLines)

        return (Self.diagnosticsFileName, lines.joined(separator: "\n"))
    }

    private func runTask(
        _ title: String,
        action: @escaping () async throws -> String
    ) {
        guard !isRunning else {
            appendLog("Another task is already running.")
            return
        }

        isRunning = true
        appendLog("=== \(title) ===")

        runningTask = Task {
            defer {
                isRunning = false
                runningTask = nil
                currentProcess = nil
            }
            do {
                try Task.checkCancellation()
                let output = try await action()
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendLog(output)
                }
                workflowState = .completed
                appendLog("=== Completed ===")
            } catch is CancellationError {
                workflowState = .canceled
                appendLog("=== Canceled ===")
            } catch {
                workflowState = .failed(error.localizedDescription)
                appendLog("Error: \(error.localizedDescription)")
                appendLog("=== Failed ===")
            }
        }
    }

    private func appendLog(_ text: String) {
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        logs.append("[\(timestamp)] \(text)")
    }

    private func inferLastActionStatus() -> String {
        for line in logs.reversed() {
            if line.contains("=== Failed ===") {
                return "Error"
            }
            if line.contains("=== Completed ===") {
                return "Completed"
            }
            if line.contains("=== Start Zoom ===") {
                return "In Progress"
            }
        }
        return "Unknown"
    }


    private func spoofMACAndReconnectActiveInterface() async throws -> MACSpoofResult {
        let interface = try await resolveActiveSupportedInterface()

        if ShellCommands.isMacSpoofingDisabledForCurrentOS() {
            return MACSpoofResult(
                summary: "MAC spoofing is disabled on macOS 14 and later because the old spoofing method no longer works reliably. Active network: \(interface.kind.rawValue) (\(interface.device), service: \(interface.networkService)).",
                hasWarning: false,
                wasSkipped: true
            )
        }

        if interface.kind == .wifi && ShellCommands.isMacSpoofingBlockedOnWiFi() {
            return try await resetPrivateWiFiAddressAndReconnect(networkService: interface.networkService, device: interface.device)
        }

        let spoofedMAC = try ShellCommands.generateRandomMACAddress()
        let spoofScript = ShellCommands.makeSpoofCommand(device: interface.device, spoofedMAC: spoofedMAC, networkService: interface.networkService)

        appendLog("Network recovery: commands to be attempted on \(interface.device) (service: \(interface.networkService))")

        let appleScript = ShellCommands.appleScriptDoShellScript(spoofScript, administratorPrivileges: true)
        let commandOutput: String
        do {
            commandOutput = try await runProcess(
                stepName: "Spoof MAC and reconnect \(interface.kind.rawValue)",
                executable: Constants.osascriptPath,
                arguments: ["-e", appleScript],
                timeout: 90
            )
        } catch {
            // Network step failed midway — log the exact commands and provide recovery
            appendLog("Network recovery: MAC spoof command failed. Commands attempted:")
            appendLog("  \(spoofScript)")
            appendLog("""
Network recovery: Your network interface may be in an inconsistent state. To restore manually:
  1. Open System Settings > Network
  2. Find '\(interface.networkService)' and turn it off, then on again
  3. Or run in Terminal: sudo /sbin/ifconfig \(interface.device) up
  4. If Wi-Fi is disconnected, click the Wi-Fi menu and reconnect to your network
""")
            throw error
        }

        let verifyScript = ShellCommands.makeVerifyMACCommand(device: interface.device)
        let actualMAC = (try? await runProcess(
            stepName: "Verify MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let macVerified = !actualMAC.isEmpty && actualMAC == spoofedMAC.lowercased()

        let summary: String
        if macVerified {
            summary = "MAC spoofed on \(interface.kind.rawValue) (\(interface.device), service: \(interface.networkService)) -> \(spoofedMAC); network service restarted"
        } else {
            let detail = actualMAC.isEmpty
                ? "Could not read the current MAC address after spoofing."
                : "Current MAC (\(actualMAC)) does not match target (\(spoofedMAC))."
            appendLog("Network recovery: MAC change was not applied. Commands attempted:")
            appendLog("  \(spoofScript)")
            summary = """
Warning: MAC address was not changed on \(interface.kind.rawValue) (\(interface.device)). \(detail)
This is a known macOS limitation on Apple Silicon Macs (macOS Sonoma 14 and later): \
the OS blocks Wi-Fi MAC spoofing at the driver level. Zoom will likely still show error 1132.
What you can try:
  1. Connect via Ethernet — MAC spoofing still works on Ethernet adapters.
  2. Use your phone as a hotspot — this gives you a different network identity entirely.
  3. Turn on Private Wi-Fi Address for your network in System Settings > Wi-Fi, \
disconnect, and reconnect before running Start Zoom again.
If your network connection is disrupted after this step:
  - Open System Settings > Network and toggle '\(interface.networkService)' off then on
  - Or run in Terminal: sudo /sbin/ifconfig \(interface.device) up
"""
        }

        let trimmedCommandOutput = commandOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedSummary: String

        if trimmedCommandOutput.isEmpty {
            combinedSummary = summary
        } else {
            combinedSummary = "\(summary)\n\(trimmedCommandOutput)"
        }

        return MACSpoofResult(
            summary: combinedSummary,
            hasWarning: combinedSummary.contains("Warning:"),
            wasSkipped: false
        )
    }

    private func resetPrivateWiFiAddressAndReconnect(networkService: String, device: String) async throws -> MACSpoofResult {
        // 1. Check current private address mode
        let getModeCmd = ShellCommands.makeGetPrivateAddressModeCommand(networkService: networkService)
        let currentModeOutput = (try? await runProcess(
            stepName: "Check Private Wi-Fi Address mode",
            executable: Constants.bashPath,
            arguments: ["-c", getModeCmd]
        )) ?? "unsupported"
        let currentMode = ShellCommands.normalizePrivateAddressModeOutput(currentModeOutput)

        appendLog("Private Wi-Fi Address mode: \(currentMode)")

        var modeWasChanged = false
        var warnings: [String] = []

        // 2. If not rotating, set it
        if currentMode == "unsupported" {
            warnings.append("Warning: Private Wi-Fi Address controls are unsupported on this macOS/networksetup version.")
        } else if currentMode != "rotating" {
            let setModeCmd = ShellCommands.makeSetPrivateAddressModeCommand(networkService: networkService, mode: "rotating")
            let setModeScript = ShellCommands.appleScriptDoShellScript(setModeCmd, administratorPrivileges: true)
            do {
                _ = try await runProcess(
                    stepName: "Enable rotating Private Wi-Fi Address",
                    executable: Constants.osascriptPath,
                    arguments: ["-e", setModeScript],
                    timeout: 15
                )
                modeWasChanged = true
                appendLog("Private Wi-Fi Address set to rotating (was: \(currentMode))")
            } catch {
                let warning = "Warning: Could not set Private Wi-Fi Address to rotating: \(error.localizedDescription)"
                warnings.append(warning)
                appendLog(warning)
            }
        }

        // 3. Cycle the interface to generate a new MAC — always brings it back up
        let resetCmd = ShellCommands.makeRotatingMACResetCommand(device: device)
        let resetScript = ShellCommands.appleScriptDoShellScript(resetCmd, administratorPrivileges: true)
        do {
            _ = try await runProcess(
                stepName: "Reset Wi-Fi to generate new rotating MAC",
                executable: Constants.osascriptPath,
                arguments: ["-e", resetScript],
                timeout: 30
            )
        } catch {
            let warning = "Warning: Wi-Fi cycle encountered an error: \(error.localizedDescription)"
            warnings.append(warning)
            appendLog(warning)
            // Interface was already brought back up by the command — log and continue
        }

        // 4. Read the new MAC for logging
        let verifyScript = ShellCommands.makeVerifyMACCommand(device: device)
        let newMAC = (try? await runProcess(
            stepName: "Read new MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(could not read)"

        let modeNote: String
        if currentMode == "unsupported" {
            modeNote = "Private Wi-Fi Address mode could not be verified on this system. "
        } else if modeWasChanged {
            modeNote = "Private Wi-Fi Address changed to rotating (was: \(currentMode)). "
        } else if currentMode == "rotating" {
            modeNote = "Private Wi-Fi Address was already set to rotating. "
        } else {
            modeNote = "Private Wi-Fi Address remained \(currentMode). "
        }

        var summaryParts = ["\(modeNote)Wi-Fi cycled to generate new rotating MAC. Current MAC: \(newMAC)"]
        summaryParts.append(contentsOf: warnings)

        return MACSpoofResult(
            summary: summaryParts.joined(separator: "\n"),
            hasWarning: !warnings.isEmpty,
            wasSkipped: false
        )
    }

    private func resolveActiveSupportedInterface() async throws -> NetworkInterfaceInfo {
        let defaultRouteOutput = try await runProcess(
            stepName: "Detect active network interface",
            executable: Constants.bashPath,
            arguments: ["-c", "/sbin/route -n get default"]
        )
        let activeDevice = try ShellCommands.parseDefaultRouteInterface(from: defaultRouteOutput)

        let hardwarePortsOutput = try await runProcess(
            stepName: "Inspect hardware ports",
            executable: Constants.bashPath,
            arguments: ["-c", "/usr/sbin/networksetup -listallhardwareports"]
        )
        let hardwarePortMap = ShellCommands.parseHardwarePorts(from: hardwarePortsOutput)

        guard let hardwarePortName = hardwarePortMap[activeDevice] else {
            throw appError("Detect active network interface: Could not map interface '\(activeDevice)' to a hardware port.")
        }

        let scKind = try ShellCommands.classifySupportedInterface(hardwarePortName: hardwarePortName)
        let kind: NetworkInterfaceInfo.Kind = scKind == .wifi ? .wifi : .ethernet

        let serviceOrderOutput = try await runProcess(
            stepName: "Inspect network services",
            executable: Constants.bashPath,
            arguments: ["-c", "/usr/sbin/networksetup -listnetworkserviceorder"]
        )
        let serviceMap = ShellCommands.parseNetworkServiceOrder(from: serviceOrderOutput)

        guard let networkService = serviceMap[activeDevice], !networkService.isEmpty else {
            throw appError("Detect active network interface: Could not resolve network service for interface '\(activeDevice)'. This can happen if the interface was renamed in System Settings or if a third-party network tool is managing your connection. Check System Settings > Network and ensure your connection is listed.")
        }

        return NetworkInterfaceInfo(
            device: activeDevice,
            hardwarePort: hardwarePortName,
            networkService: networkService,
            kind: kind
        )
    }

    private func makeLaunchZoomCommand() -> String {
        ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: zoomBinaryPath)
    }

    // MARK: - Zoom Location

    /// Prompts the user to choose a `zoom.us.app` bundle when Zoom is installed
    /// outside the default location. Sandbox-mode launch is unchanged; only the
    /// bundle location is configurable.
    func chooseZoomLocation() {
        let panel = NSOpenPanel()
        panel.title = "Select Zoom Application"
        panel.message = "Choose the Zoom app (zoom.us.app) if it is installed outside the default Applications folder."
        panel.prompt = "Select"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let selectedPath = url.path
        guard let validated = ZoomLocation.validatedAppPath(selectedPath) else {
            appendLog("Selected app is not a valid Zoom installation: \(selectedPath)")
            workflowState = .failed("The selected app does not contain the Zoom executable. Choose 'zoom.us.app'.")
            return
        }

        ZoomLocation.customAppPath = validated
        customZoomAppPath = validated
        appendLog("Zoom location set to: \(validated)")
        runPreflight()
    }

    /// Reverts to the default `/Applications/zoom.us.app` location.
    func resetZoomLocation() {
        ZoomLocation.customAppPath = nil
        customZoomAppPath = nil
        appendLog("Zoom location reset to default: \(ZoomLocation.defaultAppPath)")
        runPreflight()
    }

    private func ensureMediaAccessForSandboxedZoom() async throws -> String {
        let cameraStatus = try await ensureMediaAccess(
            mediaType: .video,
            displayName: "Camera",
            usageDescriptionKey: "NSCameraUsageDescription"
        )
        let microphoneStatus = try await ensureMediaAccess(
            mediaType: .audio,
            displayName: "Microphone",
            usageDescriptionKey: "NSMicrophoneUsageDescription"
        )

        return "\(cameraStatus); \(microphoneStatus)"
    }

    private func ensureMediaAccess(
        mediaType: AVMediaType,
        displayName: String,
        usageDescriptionKey: String
    ) async throws -> String {
        guard Bundle.main.object(forInfoDictionaryKey: usageDescriptionKey) != nil else {
            throw appError("\(displayName) access cannot be requested because \(usageDescriptionKey) is missing from the app bundle.")
        }

        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return "\(displayName) access already granted"
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: mediaType)
            if granted {
                return "\(displayName) access granted"
            }
            throw appError("\(displayName) access was denied. Enable 1132 Fixer in System Settings > Privacy & Security > \(displayName), then run Start Zoom again.")
        case .denied:
            throw appError("\(displayName) access is denied. Enable 1132 Fixer in System Settings > Privacy & Security > \(displayName), then run Start Zoom again.")
        case .restricted:
            throw appError("\(displayName) access is restricted by macOS or device management policy.")
        @unknown default:
            throw appError("\(displayName) access is in an unknown authorization state.")
        }
    }

    private func appError(_ message: String) -> NSError {
        NSError(
            domain: Constants.errorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private final class ContinuationResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResumed = false

        func beginResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !hasResumed else { return false }
            hasResumed = true
            return true
        }
    }

    private func runProcess(stepName: String, executable: String, arguments: [String], timeout: TimeInterval = 60) async throws -> String {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        currentProcess = process

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            let stdoutBuffer = LockedDataBuffer()
            let stderrBuffer = LockedDataBuffer()
            let resumeGate = ContinuationResumeGate()

            @Sendable func safeResume(_ result: Result<String, Error>) {
                guard resumeGate.beginResume() else { return }
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
            }

            // Timeout timer
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                process.terminate()
                DispatchQueue.main.async {
                    self.appendLog("Timeout: '\(stepName)' did not complete within \(Int(timeout))s — terminating.")
                }
                safeResume(.failure(NSError(
                    domain: Constants.errorDomain,
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "\(stepName): Timed out after \(Int(timeout)) seconds."]
                )))
            }
            timer.resume()

            do {
                process.terminationHandler = { terminatedProcess in
                    timer.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil

                    let outData = stdoutBuffer.snapshot()
                    let errData = stderrBuffer.snapshot()

                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    let combined = [stdout, stderr]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")

                    if terminatedProcess.terminationStatus == 0 {
                        safeResume(.success(combined))
                        return
                    }

                    let trimmedOutput = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message: String
                    if !trimmedOutput.isEmpty {
                        message = "\(stepName): \(trimmedOutput)"
                    } else if executable == Constants.osascriptPath {
                        message = "\(stepName): Admin authorization was canceled or failed. This step requires your macOS password to run with elevated privileges. Click Start Zoom again and enter your password when prompted."
                    } else {
                        message = "\(stepName): Command failed with exit code \(terminatedProcess.terminationStatus)."
                    }

                    safeResume(.failure(NSError(
                        domain: Constants.errorDomain,
                        code: Int(terminatedProcess.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )))
                }

                try process.run()
            } catch {
                timer.cancel()
                safeResume(.failure(error))
            }
        }
    }

}

/// Shared design tokens. Spacing follows an 8-point system; radii, typography and
/// surface treatments are defined once so every panel and control matches.
private enum Design {
    // 8-point spacing scale
    static let s1: CGFloat = 8
    static let s2: CGFloat = 16
    static let s3: CGFloat = 24
    static let s4: CGFloat = 32

    // Corner radii
    static let panelRadius: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 10
    static let badgeRadius: CGFloat = 999

    // Control metrics
    static let controlHeight: CGFloat = 32
    static let iconColumn: CGFloat = 18

    // Surfaces
    static let panelFill = Color.white.opacity(0.05)
    static let panelStroke = Color.white.opacity(0.08)
    static let controlFill = Color.white.opacity(0.08)
    static let controlStroke = Color.white.opacity(0.10)

    // Text
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.45)

    static let accent = Color(red: 0.13, green: 0.50, blue: 0.86)
    static let neutralAccent = Color(red: 0.62, green: 0.66, blue: 0.72)
}

/// Lightweight panel chrome: soft fill, hairline stroke, generous radius.
private struct PanelChrome: ViewModifier {
    var padding: CGFloat = Design.s3
    var radius: CGFloat = Design.panelRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Design.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Design.panelStroke, lineWidth: 1)
            )
    }
}

private extension View {
    func panelChrome(padding: CGFloat = Design.s3, radius: CGFloat = Design.panelRadius) -> some View {
        modifier(PanelChrome(padding: padding, radius: radius))
    }
}

/// Section heading used by every panel: fixed-width icon column + title.
private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Design.s1 + 2) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Design.primaryText.opacity(0.85))
                .frame(width: Design.iconColumn, alignment: .center)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Design.primaryText)
        }
    }
}

/// Native-feeling secondary control chrome shared by every button in the app so
/// height, radius, padding and icon spacing stay identical.
private struct SecondaryControlChrome: ViewModifier {
    var isProminent: Bool = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Design.primaryText)
            .labelStyle(ControlLabelStyle())
            .padding(.horizontal, Design.s2)
            .frame(height: Design.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous)
                    .fill(isProminent
                          ? Design.accent.opacity(isHovering ? 1.0 : 0.9)
                          : Design.controlFill.opacity(isHovering ? 1.6 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous)
                    .strokeBorder(isProminent ? Color.clear : Design.controlStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

/// Keeps icon/label spacing identical across every control.
private struct ControlLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 12, weight: .medium))
            configuration.title
        }
    }
}

private extension View {
    func secondaryControl(isProminent: Bool = false) -> some View {
        modifier(SecondaryControlChrome(isProminent: isProminent))
    }
}

/// Button style that gives every control the same pressed feedback.
private struct AppButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    private let repositoryURL = URL(string: "https://github.com/1132-Fixer/macos")!
    private let websiteURL = URL(string: "https://1132-fixer.xyz")!
    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

    @State private var updateAlertIsPresented = false
    @State private var latestRelease: ReleaseInfo?
    @State private var isReportingBug = false
    @State private var showBugReportForm = false
    @State private var bugReportEmail = ""
    @State private var bugReportMessage = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.07, blue: 0.13),
                    Color(red: 0.05, green: 0.10, blue: 0.18),
                    Color(red: 0.06, green: 0.13, blue: 0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: Design.s3) {
                HeaderCard(
                    repositoryURL: repositoryURL,
                    websiteURL: websiteURL,
                    onReportBug: { showBugReportForm = true },
                    isReportBugDisabled: isReportingBug,
                    onExportDiagnostics: { vm.exportDiagnostics(appVersion: appVersion) },
                    appVersion: appVersion
                )

                PreflightPanel(preflight: vm.preflight)

                ZoomLocationPanel(
                    appPath: vm.zoomAppPath,
                    isCustom: vm.customZoomAppPath != nil,
                    isDisabled: vm.isRunning,
                    onChoose: { vm.chooseZoomLocation() },
                    onReset: { vm.resetZoomLocation() }
                )

                HStack(spacing: Design.s2) {
                    ActionCard(
                        title: "Start Zoom",
                        subtitle: "Checks the active network, resets Zoom data, refreshes DNS cache, and launches Zoom in sandbox mode.",
                        systemImage: "video.circle.fill",
                        tint: Design.accent,
                        isPrimary: true,
                        isDisabled: vm.isRunning,
                        action: {
                            vm.startZoom()
                        }
                    )

                    if vm.isRunning {
                        ActionCard(
                            title: "Cancel",
                            subtitle: "Stop the running workflow.",
                            systemImage: "xmark.circle.fill",
                            tint: Color.red.opacity(0.85),
                            isPrimary: false,
                            isDisabled: false,
                            action: {
                                vm.cancelWorkflow()
                            }
                        )
                        .transition(.opacity)
                    } else {
                        ActionCard(
                            title: "Dry Run",
                            subtitle: "Check system state without making any changes.",
                            systemImage: "eye.circle.fill",
                            tint: Design.neutralAccent,
                            isPrimary: false,
                            isDisabled: vm.isRunning,
                            action: {
                                vm.dryRun()
                            }
                        )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if let progress = vm.workflowProgress {
                    WorkflowProgressBar(progress: progress)
                }

                LogPanel(logs: vm.logs, onCopy: vm.copyLogs, onClear: vm.clearLogs)
            }
            .padding(Design.s3)
        }
        .frame(minWidth: 720, minHeight: 640)
        .onAppear { vm.runPreflight() }
        .task {
            // Only check for updates in packaged apps that have a real version.
            guard appVersion != "dev" else { return }
            guard latestRelease == nil else { return }

            do {
                let release = try await UpdateChecker.fetchLatestRelease()
                if UpdateChecker.isUpdateAvailable(currentVersion: appVersion, latestVersion: release.version) {
                    latestRelease = release
                    updateAlertIsPresented = true
                }
            } catch {
                // Silent failure: update checks should never block app usage.
            }
        }
        .alert("Update Available", isPresented: $updateAlertIsPresented) {
            Button("Download Update") {
                NSWorkspace.shared.open(websiteURL)
            }
            Button("Later", role: .cancel) {}
        } message: {
            if let release = latestRelease {
                if let notes = release.releaseNotes, !notes.isEmpty {
                    Text("Version \(release.version) is available. You have \(appVersion).\n\n\(notes)")
                } else {
                    Text("Version \(release.version) is available. You have \(appVersion).")
                }
            } else {
                Text("A newer version is available.")
            }
        }
        .sheet(isPresented: $showBugReportForm) {
            BugReportFormSheet(
                email: $bugReportEmail,
                message: $bugReportMessage,
                isSubmitting: isReportingBug,
                onCancel: { showBugReportForm = false },
                onSubmit: {
                    Task {
                        await reportBug(email: bugReportEmail, message: bugReportMessage)
                    }
                }
            )
        }
    }

    @MainActor
    private func reportBug(email: String, message: String) async {
        guard !isReportingBug else { return }
        isReportingBug = true
        defer { isReportingBug = false }

        vm.logMessage("=== Report a Bug ===")
        let draft = vm.makeBugReportDraft(appVersion: appVersion)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportMessage = trimmedMessage.isEmpty ? "No user message provided." : trimmedMessage

        do {
            try await BugReportService.sendBugReport(
                title: draft.title,
                email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                message: reportMessage,
                systemInfo: draft.systemInfo,
                diagnosticsFileName: draft.diagnosticsFileName,
                diagnosticsData: draft.diagnosticsData
            )
            vm.logMessage("Bug report submitted successfully.")
            showBugReportForm = false
            bugReportEmail = ""
            bugReportMessage = ""
        } catch {
            vm.logMessage("Bug report failed: \(error.localizedDescription)")
        }
    }
}

private struct BugReportFormSheet: View {
    @Binding var email: String
    @Binding var message: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.s2) {
            Text("Report a bug")
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            Text("Add an optional email and a message.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Design.s1) {
                Text("E-mail or Telegram (optional)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                TextField("user@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
            }

            VStack(alignment: .leading, spacing: Design.s1) {
                Text("Message")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                TextEditor(text: $message)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .frame(minHeight: 120)
                    .padding(Design.s1)
                    .background(
                        RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous)
                            .fill(Color.black.opacity(0.08))
                    )
                    .disabled(isSubmitting)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Sending..." : "Send Report", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting)
            }
        }
        .padding(Design.s3)
        .frame(width: 480)
    }
}

private struct HeaderCard: View {
    let repositoryURL: URL
    let websiteURL: URL
    let onReportBug: () -> Void
    let isReportBugDisabled: Bool
    let onExportDiagnostics: () -> Void
    let appVersion: String

    var body: some View {
        HStack(alignment: .center, spacing: Design.s2) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "video.badge.waveform.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Design.primaryText)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("1132 Fixer")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Design.primaryText)
                Text("Zoom diagnostic & repair")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Design.secondaryText)
            }

            Spacer(minLength: Design.s2)

            HStack(spacing: Design.s1) {
                HeaderLinkButton(title: "GitHub", systemImage: "link", destination: repositoryURL)
                HeaderLinkButton(title: "Website", systemImage: "globe", destination: websiteURL)
                HeaderActionButton(
                    title: "Report a bug",
                    systemImage: "ladybug",
                    isDisabled: isReportBugDisabled,
                    action: onReportBug
                )
                HeaderActionButton(
                    title: "Export Diagnostics",
                    systemImage: "square.and.arrow.up",
                    isDisabled: false,
                    action: onExportDiagnostics
                )
            }
            .fixedSize()
        }
        .panelChrome(padding: Design.s2 + 4)
    }
}

private struct HeaderLinkButton: View {
    let title: String
    let systemImage: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            Label(title, systemImage: systemImage)
                .secondaryControl()
        }
        .buttonStyle(AppButtonStyle())
    }
}

private struct HeaderActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .secondaryControl()
        }
        .buttonStyle(AppButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

private struct ActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    /// Primary cards keep the accent glow; secondary cards differ only by icon color.
    let isPrimary: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Design.s2) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 26, alignment: .center)

                VStack(alignment: .leading, spacing: Design.s1) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Design.primaryText)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(Design.secondaryText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Design.s2)

                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Design.tertiaryText)
            }
            .padding(Design.s3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .fill(isPrimary ? tint.opacity(0.10) : Design.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .strokeBorder(
                        isPrimary ? tint.opacity(isHovering ? 0.55 : 0.38) : Design.panelStroke,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isPrimary ? tint.opacity(isHovering ? 0.32 : 0.18) : .clear,
                radius: 16,
                y: 4
            )
            .opacity(isDisabled ? 0.5 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        }
        .buttonStyle(AppButtonStyle())
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
    }
}

private struct WorkflowProgressBar: View {
    let progress: AppViewModel.WorkflowProgress

    var body: some View {
        HStack(alignment: .top, spacing: Design.s1) {
            ForEach(progress.steps) { step in
                VStack(spacing: Design.s1) {
                    stepIcon(step.state)
                        .font(.system(size: 14))
                        .frame(height: 16)
                    Text(step.name)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(Design.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .panelChrome(padding: Design.s2, radius: 16)
    }

    @ViewBuilder
    private func stepIcon(_ state: AppViewModel.WorkflowProgress.StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Design.tertiaryText)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.yellow)
        }
    }
}

private struct PreflightPanel: View {
    let preflight: AppViewModel.PreflightInfo

    private static let supportMatrix: [(label: String, supported: Bool)] = [
        ("Intel", true),
        ("Apple Silicon", true),
        ("macOS 13", true),
        ("macOS 14+", true),
        ("Wi-Fi", true),
        ("Ethernet", true),
        ("VPN", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.s2) {
            SectionHeader(title: "Preflight Checks", systemImage: "checklist")

            switch preflight.status {
            case .loading:
                HStack(spacing: Design.s1) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking system...")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(Design.secondaryText)
                }
            case .error(let msg):
                Text(msg)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.9))
            case .ready:
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: Design.s3, alignment: .leading),
                        GridItem(.flexible(), spacing: Design.s3, alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: Design.s2
                ) {
                    ForEach(preflight.checks) { check in
                        HStack(alignment: .firstTextBaseline, spacing: Design.s1 + 2) {
                            Image(systemName: check.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(check.isWarning ? .yellow : .green)
                                .frame(width: Design.iconColumn, alignment: .center)
                            Text(check.label + ":")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Design.secondaryText)
                            Text(check.value)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundStyle(Design.primaryText.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.vertical, Design.s1)

            HStack(spacing: Design.s1) {
                Text("Supported:")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Design.tertiaryText)
                ForEach(Self.supportMatrix, id: \.label) { item in
                    SupportBadge(label: item.label, supported: item.supported)
                }
            }
        }
        .panelChrome()
    }
}

/// Informational pill in the support matrix — soft fill, no hard outline.
private struct SupportBadge: View {
    let label: String
    let supported: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(supported ? Color.green.opacity(0.85) : Color.red.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(supported ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
            )
    }
}

private struct ZoomLocationPanel: View {
    let appPath: String
    let isCustom: Bool
    let isDisabled: Bool
    let onChoose: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Design.s3) {
            VStack(alignment: .leading, spacing: Design.s1 + 4) {
                HStack(spacing: Design.s1) {
                    SectionHeader(title: "Zoom Location", systemImage: "folder")
                    if isCustom {
                        Text("Custom")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Design.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Design.accent.opacity(0.16))
                            )
                    }
                }

                Text(appPath)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(Design.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: Design.s2)

            HStack(spacing: Design.s1) {
                if isCustom {
                    Button(action: onReset) {
                        Text("Use Default")
                            .secondaryControl()
                    }
                    .buttonStyle(AppButtonStyle())
                    .disabled(isDisabled)
                    .opacity(isDisabled ? 0.5 : 1.0)
                }

                Button(action: onChoose) {
                    Label("Choose Location…", systemImage: "folder")
                        .secondaryControl(isProminent: true)
                }
                .buttonStyle(AppButtonStyle())
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.5 : 1.0)
            }
            .fixedSize()
        }
        .panelChrome()
    }
}

private struct LogPanel: View {
    let logs: [String]
    let onCopy: () -> Void
    let onClear: () -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: Design.s2) {
            HStack(spacing: Design.s1) {
                SectionHeader(title: "Activity Log", systemImage: "terminal")

                Spacer(minLength: Design.s2)

                Button(action: onCopy) {
                    Text("Copy").secondaryControl()
                }
                .buttonStyle(AppButtonStyle())
                .disabled(logs.isEmpty)
                .opacity(logs.isEmpty ? 0.5 : 1.0)

                Button(action: onClear) {
                    Text("Clear").secondaryControl()
                }
                .buttonStyle(AppButtonStyle())
                .disabled(logs.isEmpty)
                .opacity(logs.isEmpty ? 0.5 : 1.0)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 14)
                        .secondaryControl()
                }
                .buttonStyle(AppButtonStyle())
                .help(isExpanded ? "Collapse activity log" : "Expand activity log")
            }

            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if logs.isEmpty {
                            Text("No logs yet. Run an action to see output.")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(Design.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Design.s1)
                        } else {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Design.primaryText.opacity(0.85))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, Design.s1 + 2)
                                    .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.03))
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxHeight: .infinity)
            }
        }
        .panelChrome()
        .frame(maxHeight: isExpanded ? .infinity : nil, alignment: .topLeading)
    }
}
