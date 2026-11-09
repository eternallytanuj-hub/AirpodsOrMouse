# AirPodWand (`AirpodsOrMouse`)

Turn AirPods (AirPods 4, AirPods Pro, AirPods 3, AirPods Max) into a handheld 6-DoF macOS cursor controller and gesture mouse using native Apple frameworks (`CoreMotion`, `CoreAudio`, `AVFoundation`, `MediaPlayer`, `CoreGraphics`) with **zero external dependencies**.

---

## Requirements

- **Mac**: macOS 14+ (Sonoma or newer) with Bluetooth
- **Toolchain**: Xcode 16+ or Apple Command Line Tools (`swift --version` 6.0+)
- **Headphones**: Paired AirPods supporting CoreMotion Headphone Motion (`CMHeadphoneMotionManager`)

---

## Build & Verify (Pure-Software Self-Check)

Clone the repository and build from the repository root:

```bash
git clone https://github.com/eternallytanuj-hub/AirpodsOrMouse.git
cd AirpodsOrMouse
swift build -c release
```

Verify the full DSP and gesture pipeline without hardware first:

```bash
.build/release/AirPodWandCLI --simulate-e2e
```

Expected output ends with `E2E_SOFTWARE_VERIFICATION_PASSED` (`exit 0`).

---

## Running Live on Your Mac

1. **Connect your AirPods** to your Mac via Bluetooth.
2. **Start the driver** from the repo directory:
   ```bash
   .build/release/AirPodWandCLI --live
   ```
   *(Optional install for system-wide launching — `Info.plist` is embedded directly into the Mach-O binary):*
   ```bash
   sudo cp .build/release/AirPodWandCLI /usr/local/bin/airpodwand
   airpodwand --live
   ```
3. **Grant macOS Permissions** when prompted (or in **System Settings → Privacy & Security**):
   - **Motion & Fitness**: Allow access so `CMHeadphoneMotionManager` can read 100 Hz AirPods IMU telemetry.
   - **Accessibility**: Allow your Terminal app (or `AirPodWandCLI`) so `CGEvent` mouse clicks register across macOS apps.
4. **Hold / Wear Your AirPods**: Keep the earbud active (worn or held against the skin/in-ear sensor so macOS keeps AirPods IMU streaming). AirPodWand automatically sets AirPods as the default CoreAudio output, streams a sub-audible 20 Hz keep-alive tone, and restores your previous audio output when you quit.

---

## Controls & Gestures

| Action | Gesture / Trigger | Notes |
|---|---|---|
| **Auto-Calibrate Zero Grip** | Hold still for ~300 ms | Automatically aligns cursor axes to your grip angle |
| **Move Cursor** | Tilt / pan wrist or head smoothly | Filtered via adaptive 1€ filter + sigmoid velocity curve |
| **Left Click** | Quick **clockwise** axial roll twist, **Hover-Dwell** (move ≥ 25 px, hold steady 450 ms within 4 px), or **Single Stem Pinch** (`togglePlayPause`) | Cursor locks for 180 ms during roll-twist clicks to avoid click drift |
| **Right Click** | Quick **counter-clockwise** axial roll twist or **Double Stem Pinch** (`nextTrack`) | Uses 400 ms cooldown between twists |
| **Recalibrate Grip** | Rest stationary ≥ 3 seconds then hold still 300 ms, or **Triple Stem Pinch** (`previousTrack`) | Re-zeros grip reference orientation |
| **Quit Cleanly** | Press `Ctrl+C` (`SIGINT`) or send `SIGTERM` | Halts motion updates and restores prior audio output device |

---

## CLI Options

```text
AirPodWandCLI --simulate-e2e   Run synthetic closed-loop verification (default)
AirPodWandCLI --live           Run live AirPods CoreMotion cursor controller
AirPodWandCLI --help           Show CLI help
```
