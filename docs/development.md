# Building DepthWire from source

For developers who want to build, change or study the apps. To just use DepthWire, see the [README](../README.md).

## Requirements

- A recent Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An Apple Developer account. A free account can build the iPhone app. The Mac app contains a camera extension (a system extension), which needs a paid account to sign.
- An iPhone or iPad with LiDAR on iOS 17+, and a Mac on macOS 14+

## Build

Signing settings live in one file that is never committed.

```bash
cp Config/Signing.example.xcconfig Config/Signing.xcconfig
```

Open `Config/Signing.xcconfig` and set your Team ID and a bundle prefix you own. Then generate the Xcode projects:

```bash
cd ios && xcodegen generate
```

```bash
cd mac && xcodegen generate
```

- **iPhone:** open `ios/DepthWire.xcodeproj` and run it on your phone.
- **Mac:** open `mac/DepthWire.xcodeproj`, build, and copy the app to /Applications before launching. macOS only activates camera extensions from there.

When you change code in `mac/Extension`, raise `CURRENT_PROJECT_VERSION` in `mac/project.yml`, or macOS keeps running the old extension.

## What's in the repo

| Folder | What's in it |
|---|---|
| [`ios/`](../ios) | The iPhone app: reads LiDAR depth and sends it. |
| [`mac/App`](../mac/App) | The Mac app: receiver, filters, calibration, renderer, the window. |
| [`mac/Extension`](../mac/Extension) | The CoreMediaIO camera extension other apps see. |
| [`Shared/`](../Shared) | The wire format, one file compiled into both apps. |
| [`guide/`](../guide), [`touchdesigner/`](../touchdesigner) | The toolkit's guides and starters. |

## How it works

```
iPhone: LiDAR depth ─► rotate upright ─► [depth u16 mm | confidence u8 | person mask u8 | lens + gravity]
        ─► LZ4 ─► TCP, advertised over Bonjour as _depthwire._tcp

Mac:    DepthReceiver ─► DepthPreprocessor (noise filter, steadiness)
        ─► DepthSegmenter (hide the calibrated room) ─► DepthRenderer (distances, crop, colours, size, flips)
        ─► VirtualCameraSink ─► camera extension ─► any app
```

- **Wire format.** [`Shared/DepthWireProtocol.swift`](../Shared/DepthWireProtocol.swift): a 28-byte header (magic `LDR2`, flags for which planes follow), then an LZ4 payload. Depth is 16-bit millimetres, up to 320×240.
- **Lens and gravity** travel with every frame, so the Mac can place each pixel in the room.
- **Transport.** The Mac finds the phone with Bonjour and connects over whatever link exists: Wi-Fi, Ethernet or USB. The phone also listens on port 52346. A connection that goes quiet for 3 seconds is dropped and retried.
- **Virtual camera.** The app renders BGRA frames and pushes them into the extension's sink stream; the extension republishes them on its source stream. The sizes it offers are listed in `mac/Shared/CameraConstants.swift`.
- **Precision.** A virtual camera is 8-bit. In Grayscale that is 256 steps across the chosen range: `distance = Farthest − brightness × (Farthest − Nearest)`.

## Releasing the Mac app

Archive, export with the `developer-id` method (which uploads for notarization), then export the notarized app and package it as a DMG. The app must be signed with Developer ID for its extension to load on other Macs.
