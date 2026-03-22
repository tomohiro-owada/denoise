import ArgumentParser
import Foundation
import DenoiseCore

@main
struct DenoiseCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "denoise",
        abstract: "Control the Denoise audio processor",
        discussion: """
            Real-time audio processing pipeline for virtual microphone.
            The DenoiseApp menu bar app must be running for start/stop/config commands.

            Machine-readable interface:
              denoise schema          Return full CLI specification as JSON
              denoise status          Return current state as JSON
              denoise devices --json  Return device list as JSON

            All config changes take effect immediately and are persisted.
            For negative values use -- separator: denoise config -- noise-gate-threshold -40
            """,
        subcommands: [Start.self, Stop.self, Monitor.self, Status.self,
                      Config.self, Devices.self, Install.self, Schema.self],
        defaultSubcommand: Status.self
    )
}

// MARK: - IPC Client

enum IPCClient {
    static let socketPath = "/tmp/denoise.sock"

    static func send(_ command: String) -> String? {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr)
                raw.copyMemory(from: cstr, byteCount: strlen(cstr) + 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, addrLen)
            }
        }
        guard connected == 0 else { return nil }

        let data = command.data(using: .utf8)!
        data.withUnsafeBytes { ptr in
            _ = write(sock, ptr.baseAddress!, data.count)
        }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(sock, &buffer, buffer.count)
        guard bytesRead > 0 else { return nil }
        return String(bytes: buffer[0..<bytesRead], encoding: .utf8)
    }

    static func sendOrFail(_ command: String) -> String {
        guard let response = send(command) else {
            let err: [String: Any] = ["ok": false, "error": "Cannot connect to DenoiseApp. Is it running?"]
            if let data = try? JSONSerialization.data(withJSONObject: err, options: .prettyPrinted),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
            DenoiseCLI.exit(withError: ExitCode.failure)
        }
        return response
    }
}

// MARK: - Subcommands

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start processing (mic → virtual device)")

    func run() {
        print(IPCClient.sendOrFail("start"), terminator: "")
    }
}

struct Monitor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start in monitor mode (output to speakers with delay for testing)"
    )

    func run() {
        print(IPCClient.sendOrFail("monitor"), terminator: "")
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop audio processing")

    func run() {
        print(IPCClient.sendOrFail("stop"), terminator: "")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show current state as JSON")

    func run() {
        print(IPCClient.sendOrFail("status"), terminator: "")
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set a configuration value (takes effect immediately)",
        discussion: """
            For negative values use -- separator: denoise config -- noise-gate-threshold -40
            Use 'denoise schema' to see all available keys, types, defaults, and ranges.
            """
    )

    @Argument(help: "Config key (see 'denoise schema' for full list)")
    var key: String

    @Argument(help: "Value to set")
    var value: String

    func run() {
        print(IPCClient.sendOrFail("set \(key) \(value)"), terminator: "")
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List available input microphones")

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    func run() {
        let devices = VirtualDeviceInstaller.findInputDevices()
        if json {
            let arr = devices.map { ["name": $0.name, "uid": $0.uid, "id": Int($0.id)] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            if devices.isEmpty {
                print("No input devices found.")
            } else {
                print("Available input devices:")
                for device in devices {
                    print("  \(device.name) [\(device.uid)]")
                }
            }
        }
    }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check virtual audio device installation")

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() {
        let installed = VirtualDeviceInstaller.isInstalled
        let driverName = VirtualDeviceInstaller.installedDriverName
        let deviceID = VirtualDeviceInstaller.findVirtualDevice()

        if json {
            let result: [String: Any] = [
                "installed": installed,
                "driverName": driverName as Any,
                "deviceID": deviceID as Any,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            if installed {
                print("\(driverName ?? "Virtual device") is installed.")
                if let id = deviceID {
                    print("Virtual device ID: \(id)")
                }
            } else {
                print("Virtual audio device is NOT installed.")
                print("Install with: brew install blackhole-2ch")
            }
        }
    }
}

struct Schema: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Return full CLI specification as JSON (for AI agents and automation)"
    )

    func run() {
        let schema: [String: Any] = [
            "name": "denoise",
            "version": "1.0.0",
            "description": "Real-time audio processing pipeline for virtual microphone on macOS",
            "requires": "DenoiseApp must be running (menu bar app)",
            "ipc": "/tmp/denoise.sock",
            "commands": [
                [
                    "name": "start",
                    "description": "Start processing (mic → virtual device)",
                    "args": [],
                    "destructive": false,
                ],
                [
                    "name": "stop",
                    "description": "Stop audio processing",
                    "args": [],
                    "destructive": false,
                ],
                [
                    "name": "monitor",
                    "description": "Start in monitor mode (output to speakers with delay)",
                    "args": [],
                    "destructive": false,
                ],
                [
                    "name": "status",
                    "description": "Return current state as JSON",
                    "args": [],
                    "output": "JSON object with isRunning, isMonitorMode, and all effect settings",
                    "destructive": false,
                ],
                [
                    "name": "config",
                    "description": "Set a configuration value (takes effect immediately, persisted)",
                    "args": ["key: string", "value: string"],
                    "note": "For negative values: denoise config -- key -value",
                    "destructive": false,
                ],
                [
                    "name": "devices",
                    "description": "List available input microphones",
                    "args": ["--json: output as JSON array"],
                    "destructive": false,
                ],
                [
                    "name": "install",
                    "description": "Check virtual audio device installation",
                    "args": ["--json: output as JSON"],
                    "destructive": false,
                ],
                [
                    "name": "schema",
                    "description": "Return this specification",
                    "args": [],
                    "destructive": false,
                ],
            ],
            "configKeys": [
                [
                    "key": "declicker-enabled",
                    "type": "bool",
                    "default": true,
                    "description": "Enable click/pop transient removal",
                ],
                [
                    "key": "declicker-sensitivity",
                    "type": "float",
                    "default": 4.0,
                    "range": "1.0–10.0",
                    "description": "Click detection sensitivity (higher = more aggressive)",
                ],
                [
                    "key": "noise-gate-enabled",
                    "type": "bool",
                    "default": true,
                    "description": "Enable noise gate (silence audio below threshold)",
                ],
                [
                    "key": "noise-gate-threshold",
                    "type": "float",
                    "default": -45.0,
                    "range": "-90.0–0.0",
                    "unit": "dB",
                    "description": "Audio below this level is silenced",
                ],
                [
                    "key": "eq-enabled",
                    "type": "bool",
                    "default": true,
                    "description": "Enable 3-band equalizer",
                ],
                [
                    "key": "eq-low",
                    "type": "float",
                    "default": 0.0,
                    "range": "-12.0–12.0",
                    "unit": "dB",
                    "description": "Low shelf gain at 200 Hz",
                ],
                [
                    "key": "eq-mid",
                    "type": "float",
                    "default": 0.0,
                    "range": "-12.0–12.0",
                    "unit": "dB",
                    "description": "Parametric mid gain at 1 kHz",
                ],
                [
                    "key": "eq-high",
                    "type": "float",
                    "default": 0.0,
                    "range": "-12.0–12.0",
                    "unit": "dB",
                    "description": "High shelf gain at 4 kHz",
                ],
                [
                    "key": "compressor-enabled",
                    "type": "bool",
                    "default": true,
                    "description": "Enable dynamics compressor",
                ],
                [
                    "key": "compressor-threshold",
                    "type": "float",
                    "default": -20.0,
                    "range": "-60.0–0.0",
                    "unit": "dB",
                    "description": "Compression starts above this level",
                ],
                [
                    "key": "compressor-ratio",
                    "type": "float",
                    "default": 4.0,
                    "range": "1.0–20.0",
                    "description": "Compression ratio (higher = more compression)",
                ],
                [
                    "key": "rnnoise-enabled",
                    "type": "bool",
                    "default": true,
                    "description": "Enable ML-based noise suppression (RNNoise)",
                ],
            ],
            "pipeline": [
                "DeClicker", "NoiseGate", "RNNoise", "EQ (3-band)", "Compressor (+5dB gain)"
            ],
        ]

        if let data = try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
