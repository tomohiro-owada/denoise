import Foundation
import CoreAudio

/// Represents an audio input device
public struct InputDevice: Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
}

/// Manages BlackHole virtual audio device installation and discovery
public enum VirtualDeviceInstaller {
    private static let halPluginPath = "/Library/Audio/Plug-Ins/HAL"
    private static let denoiseDriverName = "Denoise.driver"
    private static let blackHoleDriverName = "BlackHole2ch.driver"

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "\(halPluginPath)/\(denoiseDriverName)")
        || FileManager.default.fileExists(atPath: "\(halPluginPath)/\(blackHoleDriverName)")
    }

    public static var installedDriverName: String? {
        if FileManager.default.fileExists(atPath: "\(halPluginPath)/\(denoiseDriverName)") {
            return "Denoise"
        }
        if FileManager.default.fileExists(atPath: "\(halPluginPath)/\(blackHoleDriverName)") {
            return "BlackHole"
        }
        return nil
    }

    /// Find the BlackHole virtual device AudioDeviceID
    public static func findVirtualDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &devices
        )
        guard status == noErr else { return nil }

        // Prefer Denoise driver, fall back to BlackHole
        var blackHoleID: AudioDeviceID?
        for device in devices {
            if let name = getDeviceName(device) {
                if name.contains("Denoise") {
                    return device  // Denoise takes priority
                }
                if name.contains("BlackHole") {
                    blackHoleID = device
                }
            }
        }
        return blackHoleID
    }

    /// Find input (microphone) devices
    public static func findInputDevices() -> [InputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &devices
        )
        guard status == noErr else { return [] }

        var result: [InputDevice] = []
        for device in devices {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufferSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(device, &inputAddress, 0, nil, &bufferSize)
            guard status == noErr, bufferSize > 0 else { continue }

            // Allocate exact size returned by CoreAudio (handles multi-buffer devices)
            let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(bufferSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawPtr.deallocate() }
            let bufferListPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
            status = AudioObjectGetPropertyData(device, &inputAddress, 0, nil, &bufferSize, bufferListPtr)
            guard status == noErr else { continue }

            // Sum channels across all buffers
            let ablPtr = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            var channelCount: UInt32 = 0
            for buf in ablPtr { channelCount += buf.mNumberChannels }
            guard channelCount > 0 else { continue }

            if let name = getDeviceName(device), let uid = getDeviceUID(device) {
                // Skip BlackHole itself as an input source
                if uid.contains("BlackHole") || name.contains("Denoise") { continue }
                result.append(InputDevice(id: device, name: name, uid: uid))
            }
        }
        return result
    }

    private static func getStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &result)
        guard status == noErr, let cf = result else { return nil }
        return cf.takeUnretainedValue() as String
    }

    private static func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    /// Install BlackHole driver (requires admin privileges)
    public static func install(driverBundlePath: String) throws {
        let destPath = "\(halPluginPath)/\(blackHoleDriverName)"
        guard !FileManager.default.fileExists(atPath: destPath) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            """
            do shell script "cp -R '\(driverBundlePath)' '\(halPluginPath)/' && \
            launchctl stop com.apple.audio.coreaudiod && \
            launchctl start com.apple.audio.coreaudiod" with administrator privileges
            """
        ]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DenoiseError.installationFailed
        }
    }
}

public enum DenoiseError: Error, LocalizedError {
    case installationFailed
    case virtualDeviceNotFound
    case audioEngineError(String)

    public var errorDescription: String? {
        switch self {
        case .installationFailed:
            return "Virtual audio driver installation failed"
        case .virtualDeviceNotFound:
            return "Virtual audio device not found (install BlackHole or Denoise driver)"
        case .audioEngineError(let msg):
            return "Audio engine error: \(msg)"
        }
    }
}
