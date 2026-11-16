# TapSense

Turns a MacBook's built-in display into a touchscreen, using the laptop's microphone and an iPhone camera.

- **When you touched:** the built-in mic hears the tap. A finger on the lid sends a low-frequency thump through the laptop body, which separates it from sounds arriving through the air.
- **Where you touched:** an iPhone pointed at the screen (as a Continuity Camera) tracks your index fingertip with Apple's Vision hand-pose model. A one-time calibration maps camera positions to screen positions.
- **What happens:** a tap becomes a left click at that spot. Holding index and middle fingers together and moving them scrolls whatever is under them.

## Requirements

- A MacBook on macOS 15 or later (developed and tested on an M4 MacBook Air)
- An iPhone that works as a Continuity Camera (same Apple Account, Wi-Fi and Bluetooth on), on a stand, locked, rear cameras facing the laptop screen. A USB-C cable gives the steadiest video.
- Swift 6.2 (Command Line Tools are enough; Xcode is not needed)

## Build and run

```sh
open "$(Scripts/build-app.sh | tail -1)"
```

The app asks for:

| Permission | Used for |
|---|---|
| Microphone | hearing taps |
| Camera | seeing your fingertip |
| Accessibility | sending clicks and scrolls |
| Screen Recording (optional) | ignoring hands that are part of a video on screen |

The build is ad-hoc signed, so macOS asks for these again after every rebuild.

## Use

1. Frame the phone so the whole screen and your whole hand are visible in the app's camera panel.
2. Press `calibrate` and touch each of the 16 circles with your index fingertip. Firm, unhurried taps give the best mapping.
3. Tap to click. Two fingers together to scroll.

Recalibrate whenever the phone or the lid angle moves.

## Development

```sh
Scripts/test.sh                                         # unit tests
swift run -c release tapcli analyze recording.wav       # replay audio through the tap detector
swift run -c release handbench <session-dir> apple      # score hand tracking on a recorded calibration
```

Calibration runs are recorded (video, audio, tap times) under `~/Library/Application Support/TapSense/sessions/` so tracking changes can be measured offline. `AGENTS.md` has the architecture notes and the measurements behind the current thresholds.
