import Foundation

enum DiagnosticsCollector {
    static func makeSnapshot() -> [String] {
        let processInfo = ProcessInfo.processInfo
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let zoomAppPath = ZoomLocation.appPath
        let zoomBinaryPath = ZoomLocation.binaryPath
        let usingCustomZoomLocation = ZoomLocation.customAppPath != nil
        let zoomBundle = Bundle(path: zoomAppPath)

        var lines = [
            "--- Environment Snapshot ---",
            "OS build: \(run("/usr/bin/sw_vers", ["-buildVersion"]) ?? "unknown")",
            "Host architecture: \(ShellCommands.machineArchitecture())",
            "Processor count: \(processInfo.processorCount)",
            "Physical memory: \(formatBytes(processInfo.physicalMemory))",
            "System uptime: \(formatDuration(processInfo.systemUptime))",
            "Locale: \(Locale.current.identifier)",
            "Time zone: \(TimeZone.current.identifier)",
            "Sandbox launch required: yes",
            "sandbox-exec available: \(yesNo(fileManager.isExecutableFile(atPath: "/usr/bin/sandbox-exec")))",
            "Zoom app path: \(zoomAppPath)\(usingCustomZoomLocation ? " (custom)" : " (default)")",
            "Zoom app installed: \(yesNo(fileManager.fileExists(atPath: zoomAppPath)))",
            "Zoom binary executable: \(yesNo(fileManager.isExecutableFile(atPath: zoomBinaryPath)))",
            "Zoom version: \(zoomBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")",
            "Zoom build: \(zoomBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")",
            "Zoom process running: \(yesNo(processIsRunning("zoom.us")))",
            "Zoom capture helper running: \(processIsRunning("caphost") || processIsRunning("CptHost") ? "yes" : "no")",
            "MAC spoofing enabled by OS policy: \(yesNo(!ShellCommands.isMacSpoofingDisabledForCurrentOS()))",
        ]

        lines.append(contentsOf: networkSnapshot())
        lines.append(contentsOf: zoomStateSnapshot(homeDirectory: home))
        return lines
    }

    private static func networkSnapshot() -> [String] {
        guard let route = run("/sbin/route", ["-n", "get", "default"]) else {
            return ["Default route: unavailable"]
        }

        do {
            let device = try ShellCommands.parseDefaultRouteInterface(from: route)
            let ports = run("/usr/sbin/networksetup", ["-listallhardwareports"]) ?? ""
            let portName = ShellCommands.parseHardwarePorts(from: ports)[device] ?? "Unknown"
            let kind = (try? ShellCommands.classifySupportedInterface(hardwarePortName: portName))?.rawValue ?? "Unsupported"
            return [
                "Default route interface: \(device)",
                "Default route hardware port: \(portName)",
                "Default route interface type: \(kind)",
            ]
        } catch {
            return ["Default route: \(error.localizedDescription)"]
        }
    }

    private static func zoomStateSnapshot(homeDirectory: String) -> [String] {
        let paths = [
            ("Application Support", "\(homeDirectory)/Library/Application Support/zoom.us"),
            ("Cache", "\(homeDirectory)/Library/Caches/us.zoom.xos"),
            ("Preferences", "\(homeDirectory)/Library/Preferences/us.zoom.xos.plist"),
            ("Saved State", "\(homeDirectory)/Library/Saved Application State/us.zoom.xos.savedState"),
            ("Log", "\(homeDirectory)/Library/Logs/zoom.us.log"),
        ]

        return paths.map { label, path in
            "Zoom \(label) exists: \(yesNo(FileManager.default.fileExists(atPath: path)))"
        }
    }

    private static func processIsRunning(_ name: String) -> Bool {
        run("/usr/bin/pgrep", ["-x", name]) != nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        return "\(hours)h \(minutes)m"
    }
}
