import ArgumentParser
import Foundation
import DenoiseCore

@main
struct DenoiseCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "denoise",
        abstract: "Control the Denoise audio processor",
        subcommands: [Start.self, Stop.self, Monitor.self, Status.self, Config.self, Devices.self, Install.self],
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
            print("Error: Cannot connect to Denoise app. Is it running?")
            DenoiseCLI.exit(withError: ExitCode.failure)
        }
        return response
    }
}

// MARK: - Subcommands

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start audio processing")

    func run() {
        print(IPCClient.sendOrFail("start"), terminator: "")
    }
}

struct Monitor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start in monitor mode (output to speakers for testing)")

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
    static let configuration = CommandConfiguration(abstract: "Show current status")

    func run() {
        print(IPCClient.sendOrFail("status"), terminator: "")
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set a configuration value",
        discussion: "For negative values: denoise config -- noise-gate-threshold -40"
    )

    @Argument(help: "Config key (e.g. noise-gate-threshold, eq-low, compressor-ratio, rnnoise-enabled)")
    var key: String

    @Argument(help: "Value to set")
    var value: String

    func run() {
        print(IPCClient.sendOrFail("set \(key) \(value)"), terminator: "")
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List available input devices")

    func run() {
        let devices = VirtualDeviceInstaller.findInputDevices()
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

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check BlackHole installation status"
    )

    func run() {
        if VirtualDeviceInstaller.isInstalled {
            print("BlackHole 2ch is installed.")
            if let device = VirtualDeviceInstaller.findVirtualDevice() {
                print("Virtual device ID: \(device)")
            }
        } else {
            print("BlackHole 2ch is NOT installed.")
            print("Install with: brew install blackhole-2ch")
            print("Or download from: https://existential.audio/blackhole/")
        }
    }
}
