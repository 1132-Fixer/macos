import Foundation

enum ShellCommands {
    static let bashPath = "/bin/bash"
    static let osascriptPath = "/usr/bin/osascript"
    static let zoomBinaryPath = "/Applications/zoom.us.app/Contents/MacOS/zoom.us"

    // MARK: - Shell Quoting

    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\"'\"'"#) + "'"
    }

    static func appleScriptDoShellScript(_ command: String, administratorPrivileges: Bool) -> String {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let privilegeClause = administratorPrivileges ? " with administrator privileges" : ""
        return "do shell script \"\(escapedCommand)\"\(privilegeClause)"
    }

    // MARK: - Command Strings

    static let stopZoom = #"""
    if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
      /usr/bin/killall "zoom.us" 2>/dev/null || true
      echo "Zoom was running and has been closed."
      for i in {1..10}; do
        /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1 || break
        /bin/sleep 0.5
      done
      if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
        /usr/bin/killall -9 "zoom.us" 2>/dev/null || true
        /bin/sleep 1
      fi
    fi
    """#

    static let stopZoomUpdaters = #"""
    for proc in zAutoUpdate zPTUpdaterUI ZoomUpdater; do
      /usr/bin/pkill -x "$proc" 2>/dev/null || true
    done

    for domain in gui/"$(/usr/bin/id -u)" user; do
      for label in us.zoom.zAutoUpdate us.zoom.ZoomUpdater us.zoom.zPTUpdaterUI; do
        /bin/launchctl bootout "$domain" "/Library/LaunchAgents/$label.plist" 2>/dev/null || true
        /bin/launchctl bootout "$domain" "$HOME/Library/LaunchAgents/$label.plist" 2>/dev/null || true
        /bin/launchctl disable "$domain/$label" 2>/dev/null || true
      done
    done
    """#

    static let refreshDNSAppleScript = #"do shell script "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder" with administrator privileges"#

    static func makeResetZoomDataCommand(homeDirectory: String) -> String {
        let home = shellSingleQuote(homeDirectory)
        return """
        home=\(home)
        zoom_data="$home/Library/Application Support/zoom.us"
        zoom_cache="$home/Library/Caches/us.zoom.xos"
        zoom_prefs="$home/Library/Preferences/us.zoom.xos.plist"
        zoom_logs="$home/Library/Logs/zoom.us.log"
        zoom_saved_state="$home/Library/Saved Application State/us.zoom.xos.savedState"

        /bin/rm -rf "$zoom_data" "$zoom_cache" "$zoom_prefs" "$zoom_saved_state"
        /bin/rm -f "$zoom_logs"*
        HOME="$home" /usr/bin/defaults delete us.zoom.xos >/dev/null 2>&1 || true

        remaining=0
        for path in "$zoom_data" "$zoom_cache" "$zoom_prefs" "$zoom_saved_state"; do
          if [ -e "$path" ]; then
            echo "Warning: Could not remove $path" >&2
            remaining=1
          fi
        done

        if /bin/ls "$zoom_logs"* >/dev/null 2>&1; then
          echo "Warning: Could not remove Zoom log files matching $zoom_logs*" >&2
          remaining=1
        fi

        exit "$remaining"
        """
    }

    static func makeBackupZoomDataCommand() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return """
        backup_dir="$HOME/Library/Application Support/1132Fixer/Backups/\(timestamp)"
        mkdir -p "$backup_dir"
        for src in \
          "$HOME/Library/Application Support/zoom.us" \
          "$HOME/Library/Caches/us.zoom.xos" \
          "$HOME/Library/Preferences/us.zoom.xos.plist" \
          "$HOME/Library/Saved Application State/us.zoom.xos.savedState"; do
          [ -e "$src" ] && cp -a "$src" "$backup_dir/" 2>/dev/null || true
        done
        echo "$backup_dir"
        """
    }

    // MARK: - MAC Address

    static func generateRandomMACAddress() throws -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE // locally administered + unicast

        let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        guard isValidMACAddress(mac) else {
            throw NSError(
                domain: "1132Fixer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Generate MAC address: Failed to generate a valid MAC address."]
            )
        }
        return mac
    }

    static func isValidMACAddress(_ value: String) -> Bool {
        let pattern = #"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Interface Validation

    static func isSafeInterfaceName(_ value: String) -> Bool {
        let pattern = #"^[a-zA-Z0-9]+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Network Parsing

    enum InterfaceKind: String {
        case wifi = "Wi-Fi"
        case ethernet = "Ethernet"
    }

    struct InterfaceInfo {
        let device: String
        let hardwarePort: String
        let networkService: String
        let kind: InterfaceKind
    }

    static func parseDefaultRouteInterface(from output: String) throws -> String {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("interface:") else { continue }

            let value = line.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            guard isSafeInterfaceName(value) else {
                throw NSError(domain: "1132Fixer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Detect active network interface: Invalid interface name '\(value)'."])
            }
            try ensureVPNIsNotActive(interfaceName: value)
            return value
        }

        throw NSError(domain: "1132Fixer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Detect active network interface: No default route interface was found. Make sure you are connected to Wi-Fi or Ethernet. If you just disconnected a VPN, wait a few seconds for your connection to restore and try again."])
    }

    static func ensureVPNIsNotActive(interfaceName: String) throws {
        let normalized = interfaceName.lowercased()
        let vpnPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

        if vpnPrefixes.contains(where: normalized.hasPrefix) {
            throw NSError(domain: "1132Fixer", code: 1, userInfo: [NSLocalizedDescriptionKey: """
VPN detected on interface '\(interfaceName)'. \
MAC spoofing cannot work while a VPN is active because the VPN tunnel hides your real network interface. \
Turn off your VPN, wait a few seconds for your normal connection to restore, and run Start Zoom again.
"""])
        }
    }

    static func parseHardwarePorts(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentHardwarePort: String?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Hardware Port:") {
                currentHardwarePort = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.hasPrefix("Device:"), let hardwarePort = currentHardwarePort {
                let device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                if isSafeInterfaceName(device) {
                    result[device] = hardwarePort
                }
            }
        }

        return result
    }

    static func classifySupportedInterface(hardwarePortName: String) throws -> InterfaceKind {
        let normalized = hardwarePortName.lowercased()

        if normalized.contains("wi-fi") || normalized.contains("wifi") {
            return .wifi
        }
        if normalized.contains("ethernet") {
            return .ethernet
        }
        if normalized.contains("usb") && normalized.contains("lan") {
            return .ethernet
        }

        throw NSError(domain: "1132Fixer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Detect active network interface: Active interface '\(hardwarePortName)' is not supported. Only Wi-Fi and Ethernet are supported."])
    }

    static func parseNetworkServiceOrder(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        var pendingServiceName: String?

        let pattern = #"\(Hardware Port: .*?, Device: ([^)]+)\)"#
        let regex = try? NSRegularExpression(pattern: pattern)

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("("), let closingParen = line.firstIndex(of: ")"), line.index(after: closingParen) < line.endIndex {
                let nameStart = line.index(after: closingParen)
                let serviceName = line[nameStart...].trimmingCharacters(in: .whitespaces)
                if !serviceName.isEmpty && !serviceName.hasPrefix("*") {
                    pendingServiceName = serviceName
                } else {
                    pendingServiceName = nil
                }
                continue
            }

            guard line.hasPrefix("(Hardware Port:"), let serviceName = pendingServiceName, let regex else { continue }
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges > 1 else { continue }

            let deviceRange = match.range(at: 1)
            guard deviceRange.location != NSNotFound else { continue }

            let device = nsLine.substring(with: deviceRange).trimmingCharacters(in: .whitespaces)
            if isSafeInterfaceName(device) {
                result[device] = serviceName
            }
        }

        return result
    }

    // MARK: - System Checks

    static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let values = mirror.children.compactMap { child -> UInt8? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return UInt8(value)
        }
        return String(bytes: values, encoding: .ascii) ?? "unknown"
    }

    static func isMacSpoofingBlockedOnWiFi() -> Bool {
        let isAppleSilicon = machineArchitecture() == "arm64"
        let isMacOS14OrLater = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        return isAppleSilicon && isMacOS14OrLater
    }

    static func isMacSpoofingDisabledForCurrentOS() -> Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
    }

    // MARK: - Private Wi-Fi Address (Rotating MAC)

    static func makeGetPrivateAddressModeCommand(networkService: String) -> String {
        "/usr/sbin/networksetup -getPrivateNetworkAddress \(shellSingleQuote(networkService)) 2>/dev/null || echo 'unsupported'"
    }

    static func makeSetPrivateAddressModeCommand(networkService: String, mode: String) -> String {
        "/usr/sbin/networksetup -setPrivateNetworkAddress \(shellSingleQuote(networkService)) \(shellSingleQuote(mode))"
    }

    static func normalizePrivateAddressModeOutput(_ output: String) -> String {
        let normalizedLines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        for mode in ["rotating", "fixed", "static", "off"] {
            if normalizedLines.contains(mode) {
                return mode
            }
        }

        let normalizedOutput = normalizedLines.joined(separator: "\n")
        if normalizedOutput.contains("not recognized")
            || normalizedOutput.contains("unsupported")
            || normalizedOutput.contains("networksetup -printcommands") {
            return "unsupported"
        }

        for mode in ["rotating", "fixed", "static", "off"] {
            if normalizedOutput.contains(mode) {
                return mode
            }
        }

        return normalizedOutput.isEmpty ? "unsupported" : normalizedOutput
    }

    /// Cycles the Wi-Fi interface off then on to generate a new rotating MAC address.
    /// The interface is always brought back up, even if the down step fails.
    static func makeRotatingMACResetCommand(device: String) -> String {
        let off = "/usr/sbin/networksetup -setairportpower \(shellSingleQuote(device)) off"
        let sleep1 = "/bin/sleep 1"
        let on = "/usr/sbin/networksetup -setairportpower \(shellSingleQuote(device)) on"
        let sleep2 = "/bin/sleep 2"
        // Always run `on`, regardless of whether `off` succeeded
        return "{ \(off); \(sleep1); } 2>/dev/null || true; \(on); \(sleep2)"
    }

    // MARK: - MAC Spoof Command

    static func makeSpoofCommand(device: String, spoofedMAC: String, networkService: String) -> String {
        let setMACCommand = "(/sbin/ifconfig \(shellSingleQuote(device)) lladdr \(shellSingleQuote(spoofedMAC)) || /sbin/ifconfig \(shellSingleQuote(device)) ether \(shellSingleQuote(spoofedMAC)))"
        let interfaceDownCommand = "/sbin/ifconfig \(shellSingleQuote(device)) down"
        let interfaceUpCommand = "/sbin/ifconfig \(shellSingleQuote(device)) up"
        let disableServiceCommand = "/usr/sbin/networksetup -setnetworkserviceenabled \(shellSingleQuote(networkService)) off"
        let enableServiceCommand = "/usr/sbin/networksetup -setnetworkserviceenabled \(shellSingleQuote(networkService)) on"
        let sleepShort = "/bin/sleep 1"
        let sleepReconnect = "/bin/sleep 2"

        let macAttempt = "(\(interfaceDownCommand) && \(sleepShort) && \(setMACCommand)) 2>/dev/null || true"
        let restoreUp = "\(interfaceUpCommand) 2>/dev/null || true"
        let recycleService = "\(disableServiceCommand) 2>/dev/null || true; \(sleepShort); \(enableServiceCommand)"
        return "\(macAttempt); \(restoreUp); \(sleepShort); \(recycleService); \(sleepReconnect)"
    }

    static func makeVerifyMACCommand(device: String) -> String {
        "/sbin/ifconfig \(shellSingleQuote(device)) | /usr/bin/awk '/^[[:space:]]*ether /{print $2; exit}'"
    }

    // MARK: - Launch Zoom

    // Zoom must stay inside sandbox-exec for this app. Do not replace this
    // profile-backed launch with /usr/bin/open or any other normal Zoom launch.
    static let zoomSandboxProfile = """
    (version 1)
    (allow default)

    ; Camera and microphone access must remain explicit because Zoom runs under
    ; sandbox-exec for the full session, including video capture.
    (allow device-camera)
    (allow device-microphone)
    (allow mach-lookup
        (global-name "com.apple.cmio.VDCAssistant")
        (global-name "com.apple.cmio.AppleCameraAssistant")
        (global-name "com.apple.cmio.registerassistantservice")
        (global-name "com.apple.tccd")
        (global-name "com.apple.audio.coreaudiod")
        (global-name "com.apple.audio.AudioComponentRegistrar")
    )

    (deny iokit-get-properties
        (iokit-property "IOPlatformSerialNumber")
        (iokit-property "IOPlatformUUID")
        (iokit-property "board-id")
        (iokit-property "IOMACAddress")
    )
    (deny file-read-data
        (literal "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist")
    )
    """

    static func makeLaunchZoomCommand() -> String {
        makeLaunchZoomCommand(zoomBinaryExists: FileManager.default.fileExists(atPath: zoomBinaryPath))
    }

    static func makeLaunchZoomCommand(zoomBinaryExists: Bool) -> String {
        guard zoomBinaryExists else {
            return #"""
            echo "Launch mode: sandboxRequiredMissingBinary"
            echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at /Applications/zoom.us.app/Contents/MacOS/zoom.us. Install Zoom from https://zoom.us/download and try again."
            exit 1
            """#
        }

        let encodedProfile = Data(zoomSandboxProfile.utf8).base64EncodedString()
        return """
        /bin/bash -c '
        set -u

        zoom_binary=\(shellSingleQuote(zoomBinaryPath))
        encoded_profile=\(shellSingleQuote(encodedProfile))
        profile_path="$(/usr/bin/mktemp "/tmp/1132fixer.zoom-sandbox.XXXXXX")" || exit 1

        cleanup() {
          /bin/rm -f "$profile_path"
        }

        wait_for_sandboxed_zoom_stability() {
          required_consecutive="$1"
          max_attempts="$2"
          i=0
          stable=0
          while [ "$i" -lt "$max_attempts" ]; do
            if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
              stable=$((stable + 1))
              if [ "$stable" -ge "$required_consecutive" ]; then
                return 0
              fi
            else
              stable=0
            fi
            /bin/sleep 1
            i=$((i + 1))
          done
          return 1
        }

        stop_zoom_processes() {
          if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
            /usr/bin/killall "zoom.us" 2>/dev/null || true
            for i in {1..6}; do
              /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1 || break
              /bin/sleep 0.5
            done
            if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
              /usr/bin/killall -9 "zoom.us" 2>/dev/null || true
              /bin/sleep 1
            fi
          fi
        }

        trap cleanup EXIT
        /bin/echo "$encoded_profile" | /usr/bin/base64 --decode > "$profile_path" || exit 1

        # Sandbox mode is required for 1132 Fixer. Normal Zoom launch mode does
        # not work for this workflow, so there is intentionally no open -a
        # fallback here.
        echo "Launch mode: persistentSandbox"
        stop_zoom_processes
        /usr/bin/sandbox-exec -f "$profile_path" "$zoom_binary" >/dev/null 2>&1 &
        sandbox_pid=$!
        /bin/sleep 1

        if /bin/kill -0 "$sandbox_pid" 2>/dev/null || /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
          echo "Heuristic: sandbox launch started"
        else
          echo "Heuristic: sandbox launch started = no"
          exit 1
        fi

        if wait_for_sandboxed_zoom_stability 4 15; then
          echo "Heuristic: sandbox launch stabilized"
          exit 0
        fi

        if /bin/kill -0 "$sandbox_pid" 2>/dev/null; then
          echo "Heuristic: sandbox process still running without process-name stability confirmation"
          exit 0
        fi

        echo "Heuristic: sandbox launch stabilized = no"
        exit 1
        '
        """
    }
}
