import SwiftUI
import CoreAudio
import DenoiseCore

struct MenuBarView: View {
    @ObservedObject var processor: AudioProcessor
    @State private var inputDevices: [InputDevice] = []
    @State private var selectedDeviceUID: String = ""
    @State private var monitorMode: Bool = false
    @State private var settings = DenoiseSettings.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "mic.badge.plus")
                    .font(.title2)
                Text("Denoise")
                    .font(.title2.bold())
                Spacer()
                statusIndicator
            }
            .padding(.bottom, 4)

            Divider()

            // Processing toggle
            HStack {
                Label("Processing", systemImage: processor.isRunning ? "power.circle.fill" : "power.circle")
                    .font(.headline)
                Spacer()
                if processor.isRunning {
                    Text(processor.isMonitorMode ? "Monitor" : "Denoise")
                        .foregroundColor(processor.isMonitorMode ? .orange : .green)
                        .font(.caption)
                }
                Toggle("", isOn: Binding(
                    get: { processor.isRunning },
                    set: { on in
                        if on {
                            startProcessing()
                        } else {
                            processor.stop()
                        }
                        saveSettings()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            // Monitor mode toggle
            Toggle(isOn: $monitorMode) {
                Label("Monitor (speakers)", systemImage: "headphones")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .onChange(of: monitorMode) { _, _ in
                if processor.isRunning {
                    startProcessing()
                }
            }

            if monitorMode {
                HStack {
                    Text("Delay")
                    Slider(value: $processor.monitorDelaySeconds, in: 0...10, step: 0.5)
                    Text("\(String(format: "%.1f", processor.monitorDelaySeconds))s")
                        .frame(width: 35)
                    Button("Apply") {
                        if processor.isRunning {
                            startProcessing()
                        }
                    }
                    .font(.caption2)
                }
                .font(.caption)
            }

            // Input device
            Picker("Input Device", selection: $selectedDeviceUID) {
                Text("Default").tag("")
                ForEach(inputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .onChange(of: selectedDeviceUID) { _, _ in
                settings.inputDeviceUID = selectedDeviceUID.isEmpty ? nil : selectedDeviceUID
                saveSettings()
            }

            // Level meters
            if processor.isRunning {
                LevelMeterView(label: "In", level: processor.inputLevel)
                LevelMeterView(label: "Out", level: processor.outputLevel)
            }

            Divider()

            // Noise Gate
            DisclosureGroup("Noise Gate") {
                Toggle("Enabled", isOn: $processor.noiseGateEnabled)
                    .onChange(of: processor.noiseGateEnabled) { _, _ in saveSettings() }
                HStack {
                    Text("Threshold")
                    Slider(value: $processor.noiseGateThreshold, in: -90...0)
                    Text("\(Int(processor.noiseGateThreshold)) dB")
                        .frame(width: 50)
                }
                .onChange(of: processor.noiseGateThreshold) { _, _ in saveSettings() }
            }

            // EQ
            DisclosureGroup("Equalizer") {
                Toggle("Enabled", isOn: $processor.eqEnabled)
                    .onChange(of: processor.eqEnabled) { _, _ in
                        processor.updateEQ()
                        saveSettings()
                    }
                eqSlider("Low", value: $processor.eqLowGain)
                eqSlider("Mid", value: $processor.eqMidGain)
                eqSlider("High", value: $processor.eqHighGain)
            }

            // Compressor
            DisclosureGroup("Compressor") {
                Toggle("Enabled", isOn: $processor.compressorEnabled)
                    .onChange(of: processor.compressorEnabled) { _, _ in
                        processor.updateCompressor()
                        saveSettings()
                    }
                HStack {
                    Text("Threshold")
                    Slider(value: $processor.compressorThreshold, in: -60...0)
                    Text("\(Int(processor.compressorThreshold)) dB")
                        .frame(width: 50)
                }
                .onChange(of: processor.compressorThreshold) { _, _ in
                    processor.updateCompressor()
                    saveSettings()
                }
            }

            // RNNoise
            Toggle(isOn: $processor.rnnoiseEnabled) {
                Label("RNNoise Suppression", systemImage: "waveform.path.ecg")
            }
            .onChange(of: processor.rnnoiseEnabled) { _, _ in saveSettings() }

            Divider()

            // Virtual device status
            HStack {
                let driverName = VirtualDeviceInstaller.installedDriverName
                Image(systemName: driverName != nil ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundColor(driverName != nil ? .green : .orange)
                Text(driverName.map { "\($0) installed" } ?? "Virtual device not found")
                    .font(.caption)
            }

            // Quit button
            HStack {
                Spacer()
                Button("Quit") {
                    processor.stop()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            inputDevices = VirtualDeviceInstaller.findInputDevices()
            selectedDeviceUID = settings.inputDeviceUID ?? ""
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(processor.isRunning ? Color.green : Color.gray)
            .frame(width: 10, height: 10)
    }

    private func eqSlider(_ label: String, value: Binding<Float>) -> some View {
        HStack {
            Text(label)
                .frame(width: 35)
            Slider(value: value, in: -12...12)
            Text("\(Int(value.wrappedValue)) dB")
                .frame(width: 50)
        }
        .onChange(of: value.wrappedValue) { _, _ in
            processor.updateEQ()
            saveSettings()
        }
    }

    private func startProcessing() {
        do {
            try processor.start(monitor: monitorMode)
        } catch {
            NSLog("Denoise start failed: \(error)")
        }
    }

    private func saveSettings() {
        settings.update(from: processor)
        settings.inputDeviceUID = selectedDeviceUID.isEmpty ? nil : selectedDeviceUID
        settings.save()
    }
}

struct LevelMeterView: View {
    let label: String
    let level: Float

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 30)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(meterColor)
                        .frame(width: max(0, geo.size.width * CGFloat(min(level * 10, 1.0))))
                }
            }
            .frame(height: 8)
        }
    }

    private var meterColor: Color {
        if level > 0.08 { return .red }
        if level > 0.04 { return .yellow }
        return .green
    }
}
