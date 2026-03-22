# Denoise

macOS virtual microphone with real-time audio processing. Captures mic input, applies noise removal and audio effects, then outputs to a virtual audio device (Denoise 2ch / BlackHole 2ch) that Zoom, Meet, QuickTime etc. can select as a microphone.

## Audio Pipeline

```
Mic → DeClicker → NoiseGate → RNNoise → RingBuffer → EQ → Compressor → Virtual Device (Denoise 2ch)
      click/pop    silence      ML noise                    3-band   dynamics     ↓
      removal      gating       suppression                 EQ       +5dB gain    Zoom / QuickTime / etc.
```

## Requirements

- macOS 14+
- Virtual audio device: `brew install blackhole-2ch` (or custom Denoise driver)
- Reboot after installing the virtual audio device

## Build

```bash
swift build
```

Produces two binaries:
- `.build/debug/DenoiseApp` — Menu bar app
- `.build/debug/denoise` — CLI tool

## Setup

1. Install virtual audio device: `brew install blackhole-2ch`
2. Reboot
3. Launch: `.build/debug/DenoiseApp`
4. In Zoom/Meet/QuickTime: select **BlackHole 2ch** (or **Denoise 2ch**) as input microphone
5. In macOS System Settings → Sound → Input: keep your real microphone selected (NOT BlackHole/Denoise)

## CLI Usage

The CLI controls the menu bar app via Unix domain socket (`/tmp/denoise.sock`). The app must be running.

### Commands

```bash
denoise                  # Show current status (default command)
denoise start            # Start processing (mic → virtual device)
denoise stop             # Stop processing
denoise monitor          # Start in monitor mode (output to speakers with delay, for testing)
denoise status           # Show all settings as JSON
denoise devices          # List available input microphones
denoise install          # Check virtual audio device installation
denoise config KEY VALUE # Set a configuration value
```

### Configuration Keys

All config changes take effect immediately and are persisted.

| Key | Type | Default | Range | Description |
|-----|------|---------|-------|-------------|
| `declicker-enabled` | bool | `true` | `true`/`false` | Enable click/pop removal |
| `declicker-sensitivity` | float | `4.0` | 1.0–10.0 | Higher = more aggressive click detection |
| `noise-gate-enabled` | bool | `true` | `true`/`false` | Enable noise gate |
| `noise-gate-threshold` | float | `-45.0` | -90.0–0.0 (dB) | Audio below this level is silenced |
| `eq-enabled` | bool | `true` | `true`/`false` | Enable 3-band equalizer |
| `eq-low` | float | `0.0` | -12.0–12.0 (dB) | Low shelf gain (200 Hz) |
| `eq-mid` | float | `0.0` | -12.0–12.0 (dB) | Parametric mid gain (1 kHz) |
| `eq-high` | float | `0.0` | -12.0–12.0 (dB) | High shelf gain (4 kHz) |
| `compressor-enabled` | bool | `true` | `true`/`false` | Enable dynamics compressor |
| `compressor-threshold` | float | `-20.0` | -60.0–0.0 (dB) | Compression starts above this level |
| `compressor-ratio` | float | `4.0` | 1.0–20.0 | Compression ratio (higher = more compression) |
| `rnnoise-enabled` | bool | `true` | `true`/`false` | Enable ML-based noise suppression |

### Examples

```bash
# Basic usage
denoise start                              # Start with all defaults
denoise stop                               # Stop processing

# Monitor your processed voice through speakers (with 1s delay to avoid feedback)
denoise monitor

# Adjust noise gate (use -- for negative values)
denoise config -- noise-gate-threshold -35

# Boost low frequencies
denoise config eq-low 6

# Aggressive compression for consistent volume
denoise config -- compressor-threshold -30
denoise config compressor-ratio 8

# Disable RNNoise if it's too aggressive
denoise config rnnoise-enabled false

# Check what's running
denoise status
```

### Status Output

`denoise status` returns JSON:

```json
{
  "isRunning": true,
  "isMonitorMode": false,
  "deClicker": { "enabled": true, "sensitivity": 4.0 },
  "noiseGate": { "enabled": true, "threshold": -45.0 },
  "eq": { "enabled": true, "lowGain": 0, "midGain": 0, "highGain": 0 },
  "compressor": { "enabled": true, "threshold": -20, "ratio": 4 },
  "rnnoise": { "enabled": true },
  "monitorDelay": 1.0
}
```

## Architecture

- **DenoiseCore** — Audio processing logic (AudioProcessor, NoiseGate, DeClicker, RNNoiseWrapper, VirtualDeviceInstaller)
- **DenoiseApp** — SwiftUI menu bar app with IPC server
- **DenoiseCLI** — Command-line interface via ArgumentParser
- **CRNNoise** — RNNoise C library (BSD-3, statically linked)

Two-engine design:
- **inputEngine**: Captures from hardware mic, applies DSP (DeClicker → NoiseGate → RNNoise), writes to ring buffer
- **outputEngine**: Reads ring buffer, applies EQ and Compressor via AudioUnits, outputs to virtual audio device

## License

- Project code: See LICENSE
- RNNoise: BSD-3-Clause (xiph.org)
- BlackHole: GPL-3.0 (installed separately, not bundled)
