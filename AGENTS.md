# Denoise — AI Agent Guide

## What is this?
A macOS real-time audio processing app that creates a virtual microphone with noise removal, EQ, and compression. Other apps (Zoom, Meet, QuickTime) select the virtual device as their microphone input.

## Quick Reference

### Always do
- Run `denoise schema` first to get the full machine-readable specification
- Use `denoise status` to check current state before making changes
- Use `--` separator before negative numeric values: `denoise config -- noise-gate-threshold -40`
- Use `--json` flag on `devices` and `install` commands for structured output
- Ensure DenoiseApp is running before using CLI commands

### Never do
- Do not set macOS system input to "Denoise 2ch" or "BlackHole 2ch" — this creates a feedback loop
- Do not pass device IDs directly; use `denoise devices --json` to discover them
- Do not assume the app is running; check with `denoise status` first (connection failure = app not running)

## Architecture

```
Mic → DeClicker → NoiseGate → RNNoise → RingBuffer → EQ → Compressor → Virtual Device
```

Two AVAudioEngine instances:
- **inputEngine**: hardware mic capture + DSP processing
- **outputEngine**: ring buffer → AudioUnit effects → virtual audio device output

## CLI Commands

Get the full specification: `denoise schema`

| Command | Output | Requires App |
|---------|--------|-------------|
| `denoise status` | JSON (settings + state) | Yes |
| `denoise start` | JSON (ok/error) | Yes |
| `denoise stop` | JSON (ok/error) | Yes |
| `denoise monitor` | JSON (ok/error) | Yes |
| `denoise config KEY VALUE` | JSON (ok/error) | Yes |
| `denoise devices [--json]` | text or JSON array | No |
| `denoise install [--json]` | text or JSON | No |
| `denoise schema` | JSON specification | No |

## Error Handling

Connection failure (app not running):
```json
{"ok": false, "error": "Cannot connect to DenoiseApp. Is it running?"}
```

Config error:
```
ERROR: unknown key 'foo'
```

## Common Tasks

### Start processing for Zoom
```bash
denoise start
# Then in Zoom: select "Denoise 2ch" or "BlackHole 2ch" as microphone
```

### Test audio quality
```bash
denoise monitor
# Listen through headphones (1s delay). DO NOT use speakers (feedback).
```

### Optimize for noisy environment
```bash
denoise config -- noise-gate-threshold -35
denoise config declicker-sensitivity 6
denoise config rnnoise-enabled true
```

### Optimize for quiet room
```bash
denoise config -- noise-gate-threshold -50
denoise config declicker-sensitivity 3
```
