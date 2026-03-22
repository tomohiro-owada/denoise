import Foundation
import DenoiseCore

/// Unix domain socket IPC server for CLI communication
final class IPCServer {
    static let shared = IPCServer()
    static let socketPath = "/tmp/denoise.sock"

    private var processor: AudioProcessor?
    private var serverSocket: Int32 = -1
    private var isListening = false

    private init() {}

    func start(processor: AudioProcessor) {
        self.processor = processor

        // Remove stale socket
        unlink(IPCServer.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        IPCServer.socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr)
                raw.copyMemory(from: cstr, byteCount: strlen(cstr) + 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, addrLen)
            }
        }

        listen(serverSocket, 5)
        isListening = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while isListening {
            let client = accept(serverSocket, nil, nil)
            guard client >= 0 else { continue }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let command = String(bytes: buffer[0..<bytesRead], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let response = processCommand(command)

        let responseData = response.data(using: .utf8)!
        responseData.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress!, responseData.count)
        }
    }

    private func processCommand(_ command: String) -> String {
        guard let processor = processor else { return "ERROR: not initialized\n" }
        let parts = command.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return "ERROR: empty command\n" }

        switch cmd {
        case "start":
            do {
                try processor.start()
                return "OK: processing started\n"
            } catch {
                return "ERROR: \(error.localizedDescription)\n"
            }
        case "monitor":
            do {
                try processor.start(monitor: true)
                return "OK: monitor mode started (output to speakers)\n"
            } catch {
                return "ERROR: \(error.localizedDescription)\n"
            }
        case "stop":
            processor.stop()
            return "OK: processing stopped\n"
        case "status":
            let settings = processor.getSettings()
            if let data = try? JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted),
               let json = String(data: data, encoding: .utf8) {
                return json + "\n"
            }
            return "ERROR: failed to serialize status\n"
        case "set":
            return handleSet(parts: Array(parts.dropFirst()), processor: processor)
        default:
            return "ERROR: unknown command '\(cmd)'. Available: start, stop, status, set\n"
        }
    }

    private func handleSet(parts: [String], processor: AudioProcessor) -> String {
        guard parts.count >= 2 else { return "ERROR: usage: set <key> <value>\n" }
        let key = parts[0]
        let value = parts[1]

        switch key {
        case "declicker-enabled":
            processor.deClickerEnabled = (value == "true" || value == "1")
        case "declicker-sensitivity":
            if let v = Float(value) { processor.deClickerSensitivity = v }
        case "noise-gate-enabled":
            processor.noiseGateEnabled = (value == "true" || value == "1")
        case "noise-gate-threshold":
            if let v = Float(value) { processor.noiseGateThreshold = v }
        case "eq-enabled":
            processor.eqEnabled = (value == "true" || value == "1")
            processor.updateEQ()
        case "eq-low":
            if let v = Float(value) { processor.eqLowGain = v; processor.updateEQ() }
        case "eq-mid":
            if let v = Float(value) { processor.eqMidGain = v; processor.updateEQ() }
        case "eq-high":
            if let v = Float(value) { processor.eqHighGain = v; processor.updateEQ() }
        case "compressor-enabled":
            processor.compressorEnabled = (value == "true" || value == "1")
            processor.updateCompressor()
        case "compressor-threshold":
            if let v = Float(value) { processor.compressorThreshold = v; processor.updateCompressor() }
        case "compressor-ratio":
            if let v = Float(value) { processor.compressorRatio = v; processor.updateCompressor() }
        case "rnnoise-enabled":
            processor.rnnoiseEnabled = (value == "true" || value == "1")
        default:
            return "ERROR: unknown key '\(key)'\n"
        }

        // Persist
        var settings = DenoiseSettings.load()
        settings.update(from: processor)
        settings.save()
        return "OK: \(key) = \(value)\n"
    }

    func stop() {
        isListening = false
        if serverSocket >= 0 {
            close(serverSocket)
        }
        unlink(IPCServer.socketPath)
    }
}
