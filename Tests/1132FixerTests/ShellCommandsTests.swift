import Testing
@testable import _132Fixer

@Suite("ShellCommands")
struct ShellCommandsTests {

    // MARK: - Shell Quoting

    @Test func shellSingleQuoteSimple() {
        #expect(ShellCommands.shellSingleQuote("hello") == "'hello'")
    }

    @Test func shellSingleQuoteWithSingleQuote() {
        let result = ShellCommands.shellSingleQuote("it's")
        #expect(result.contains("'\"'\"'"))
    }

    @Test func shellSingleQuoteEmpty() {
        #expect(ShellCommands.shellSingleQuote("") == "''")
    }

    @Test func shellSingleQuoteSpecialChars() {
        #expect(ShellCommands.shellSingleQuote("a b$c;d|e") == "'a b$c;d|e'")
    }

    // MARK: - MAC Address Validation

    @Test func validMACAddress() {
        #expect(ShellCommands.isValidMACAddress("02:ab:cd:ef:12:34"))
        #expect(ShellCommands.isValidMACAddress("AA:BB:CC:DD:EE:FF"))
    }

    @Test func invalidMACAddress() {
        #expect(!ShellCommands.isValidMACAddress(""))
        #expect(!ShellCommands.isValidMACAddress("not-a-mac"))
        #expect(!ShellCommands.isValidMACAddress("02:ab:cd:ef:12"))
        #expect(!ShellCommands.isValidMACAddress("02:ab:cd:ef:12:34:56"))
        #expect(!ShellCommands.isValidMACAddress("02-ab-cd-ef-12-34"))
        #expect(!ShellCommands.isValidMACAddress("GG:HH:II:JJ:KK:LL"))
    }

    @Test func generateRandomMACAddress() throws {
        let mac = try ShellCommands.generateRandomMACAddress()
        #expect(ShellCommands.isValidMACAddress(mac))

        let firstByte = UInt8(mac.prefix(2), radix: 16)!
        #expect(firstByte & 0x02 != 0, "Locally administered bit should be set")
        #expect(firstByte & 0x01 == 0, "Unicast bit should be clear")
    }

    @Test func generatedMACsAreRandom() throws {
        let mac1 = try ShellCommands.generateRandomMACAddress()
        let mac2 = try ShellCommands.generateRandomMACAddress()
        #expect(mac1 != mac2)
    }

    // MARK: - Interface Name Validation

    @Test func safeInterfaceNames() {
        #expect(ShellCommands.isSafeInterfaceName("en0"))
        #expect(ShellCommands.isSafeInterfaceName("en1"))
        #expect(ShellCommands.isSafeInterfaceName("bridge0"))
    }

    @Test func unsafeInterfaceNames() {
        #expect(!ShellCommands.isSafeInterfaceName(""))
        #expect(!ShellCommands.isSafeInterfaceName("en 0"))
        #expect(!ShellCommands.isSafeInterfaceName("en0;rm"))
        #expect(!ShellCommands.isSafeInterfaceName("en0|cat"))
        #expect(!ShellCommands.isSafeInterfaceName("../etc"))
    }

    // MARK: - Parse Default Route

    @Test func parseDefaultRouteInterface() throws {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        let device = try ShellCommands.parseDefaultRouteInterface(from: output)
        #expect(device == "en0")
    }

    @Test func parseDefaultRouteNoInterface() {
        let output = "route: writing to routing socket: not in table"
        #expect(throws: (any Error).self) {
            try ShellCommands.parseDefaultRouteInterface(from: output)
        }
    }

    @Test func parseDefaultRouteVPNInterface() {
        let output = """
           route to: default
          interface: utun0
        """
        #expect(throws: (any Error).self) {
            try ShellCommands.parseDefaultRouteInterface(from: output)
        }
    }

    // MARK: - Parse Hardware Ports

    @Test func parseHardwarePorts() {
        let output = """
        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: aa:bb:cc:dd:ee:ff

        Hardware Port: Thunderbolt Ethernet Slot 1
        Device: en1
        Ethernet Address: 11:22:33:44:55:66
        """
        let result = ShellCommands.parseHardwarePorts(from: output)
        #expect(result["en0"] == "Wi-Fi")
        #expect(result["en1"] == "Thunderbolt Ethernet Slot 1")
    }

    @Test func parseHardwarePortsEmpty() {
        let result = ShellCommands.parseHardwarePorts(from: "")
        #expect(result.isEmpty)
    }

    // MARK: - Classify Interface

    @Test func classifyWiFi() throws {
        let kind = try ShellCommands.classifySupportedInterface(hardwarePortName: "Wi-Fi")
        #expect(kind == .wifi)
    }

    @Test func classifyEthernet() throws {
        let kind = try ShellCommands.classifySupportedInterface(hardwarePortName: "Thunderbolt Ethernet Slot 1")
        #expect(kind == .ethernet)
    }

    @Test func classifyUSBLANAsEthernet() throws {
        let kind = try ShellCommands.classifySupportedInterface(hardwarePortName: "USB 10/100/1000 LAN")
        #expect(kind == .ethernet)
    }

    @Test func classifyUnsupported() {
        #expect(throws: (any Error).self) {
            try ShellCommands.classifySupportedInterface(hardwarePortName: "Bluetooth PAN")
        }
    }

    // MARK: - Parse Network Service Order

    @Test func parseNetworkServiceOrder() {
        let output = """
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (2) Thunderbolt Ethernet Slot 1
        (Hardware Port: Thunderbolt Ethernet Slot 1, Device: en1)
        """
        let result = ShellCommands.parseNetworkServiceOrder(from: output)
        #expect(result["en0"] == "Wi-Fi")
        #expect(result["en1"] == "Thunderbolt Ethernet Slot 1")
    }

    // MARK: - AppleScript Generation

    @Test func appleScriptDoShellScript() {
        let result = ShellCommands.appleScriptDoShellScript("echo hello", administratorPrivileges: false)
        #expect(result == #"do shell script "echo hello""#)
    }

    @Test func appleScriptDoShellScriptAdmin() {
        let result = ShellCommands.appleScriptDoShellScript("echo hello", administratorPrivileges: true)
        #expect(result == #"do shell script "echo hello" with administrator privileges"#)
    }

    @Test func appleScriptEscapesBackslashes() {
        let result = ShellCommands.appleScriptDoShellScript(#"echo \"test\""#, administratorPrivileges: false)
        #expect(result.contains("\\\\"))
    }

    // MARK: - VPN Detection

    @Test func vpnDetection() {
        #expect(throws: (any Error).self) { try ShellCommands.ensureVPNIsNotActive(interfaceName: "utun0") }
        #expect(throws: (any Error).self) { try ShellCommands.ensureVPNIsNotActive(interfaceName: "ppp0") }
        #expect(throws: (any Error).self) { try ShellCommands.ensureVPNIsNotActive(interfaceName: "ipsec0") }
        try! ShellCommands.ensureVPNIsNotActive(interfaceName: "en0")
        try! ShellCommands.ensureVPNIsNotActive(interfaceName: "en1")
    }

    // MARK: - Spoof Command Generation

    @Test func makeSpoofCommand() {
        let cmd = ShellCommands.makeSpoofCommand(device: "en0", spoofedMAC: "02:ab:cd:ef:12:34", networkService: "Wi-Fi")
        #expect(cmd.contains("ifconfig"))
        #expect(cmd.contains("'en0'"))
        #expect(cmd.contains("'02:ab:cd:ef:12:34'"))
        #expect(cmd.contains("networksetup"))
        #expect(cmd.contains("'Wi-Fi'"))
    }

    @Test func makeVerifyMACCommand() {
        let cmd = ShellCommands.makeVerifyMACCommand(device: "en0")
        #expect(cmd.contains("ifconfig"))
        #expect(cmd.contains("'en0'"))
        #expect(cmd.contains("ether"))
    }

    @Test func normalizePrivateAddressModeOutput() {
        #expect(ShellCommands.normalizePrivateAddressModeOutput("Rotating\n") == "rotating")
        #expect(ShellCommands.normalizePrivateAddressModeOutput("** Error: The command is not recognized.") == "unsupported")
        #expect(ShellCommands.normalizePrivateAddressModeOutput("networksetup -listnetworkserviceorder\nnetworksetup -printcommands") == "unsupported")
    }

    @Test func makeResetZoomDataCommandUsesProvidedHome() {
        let cmd = ShellCommands.makeResetZoomDataCommand(homeDirectory: "/Users/test user")
        #expect(cmd.contains("home='/Users/test user'"))
        #expect(cmd.contains("Application Support/zoom.us"))
        #expect(cmd.contains("exit \"$remaining\""))
    }

    @Test func zoomSandboxProfileAllowsCameraAndMicrophone() {
        #expect(ShellCommands.zoomSandboxProfile.contains("(allow device-camera)"))
        #expect(ShellCommands.zoomSandboxProfile.contains("(allow device-microphone)"))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.cmio.VDCAssistant""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.tccd""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.tccd.system""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.applecamerad""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.appleh13camerad""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.appleh16camerad""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.cmio.registerassistantservice.system-extensions""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.videoconference.camera""#))
    }

    @Test func makeLaunchZoomCommandUsesPersistentSandboxOnly() {
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: true)
        #expect(cmd.contains("Launch mode: persistentSandbox"))
        #expect(cmd.contains("/usr/bin/sandbox-exec"))
        #expect(!cmd.contains(#"/usr/bin/open -a "zoom.us""#))
        #expect(!cmd.contains("launch_normal_zoom"))
        #expect(!cmd.contains("normalOpen"))
    }

    @Test func makeLaunchZoomCommandFailsWhenZoomBinaryIsMissing() {
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: false)
        #expect(cmd.contains("Launch mode: sandboxRequiredMissingBinary"))
        #expect(cmd.contains("Zoom must be launched in sandbox mode"))
        #expect(!cmd.contains(#"/usr/bin/open -a "zoom.us""#))
        #expect(!cmd.contains("/usr/bin/sandbox-exec"))
    }

    // MARK: - Machine Architecture

    @Test func machineArchitecture() {
        let arch = ShellCommands.machineArchitecture()
        #expect(!arch.isEmpty)
        #expect(arch == "arm64" || arch == "x86_64")
    }
}
