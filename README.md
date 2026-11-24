# DepthWire

Turn an iPhone's LiDAR scanner into a depth camera for your Mac.

DepthWire is two small apps that work together:

| App | Folder | What it does |
|---|---|---|
| **DepthWire** (iPhone) | [`ios/`](ios) | Reads depth from the LiDAR scanner and streams it to your Mac over Wi-Fi, Ethernet or USB. |
| **DepthWire for Mac** | [`mac/`](mac) | Receives the depth, cleans it up, and publishes it as a **virtual camera** called "DepthWire" that any app can pick: TouchDesigner, OBS, Zoom, QuickTime, Unity. |

It was built for an interactive projection install where a Kinect or Orbbec wasn't available. A phone on a tripod did the job.

> **Status: early.** Both apps work and build from this repo. Releases (App Store for iPhone, a signed download for Mac) and raw depth output are in progress. See [Roadmap](#roadmap).

## How it works

```
iPhone                                   Mac
LiDAR depth (up to 320×240, 30 fps)      DepthWire for Mac
  → rotate upright                         → confidence filter, smoothing
  → [depth mm | confidence | person mask]  → optional: remove the empty room, 3D crop box
  → LZ4 → TCP (Bonjour _depthwire._tcp)    → colour palette → virtual camera "DepthWire"
```

- **Depth** is sent as 16-bit millimetres, so the Mac gets real distances, not a picture of them.
- **Lens and gravity** travel with every frame, so the Mac can place each pixel in the room.
- **Works in the dark.** LiDAR doesn't need light, and a projector's picture on the wall doesn't read as movement.
- **Wired or wireless.** Wi-Fi works out of the box. For long shows, a USB-C Ethernet adapter on each end is steadier; the phone also listens on a fixed port (52346) for USB.

The wire format is one file, [`Shared/DepthWireProtocol.swift`](Shared/DepthWireProtocol.swift), compiled into both apps.

## Requirements

- An iPhone or iPad with a LiDAR scanner (iPhone 12 Pro or later Pro models), iOS 17+.
- A Mac on macOS 14+.
- To build: a recent Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- An Apple Developer account. A free account can build the iPhone app. The Mac app contains a camera extension (a system extension), which needs a paid account to sign.

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

Open `ios/DepthWire.xcodeproj` and run it on your phone. Open `mac/DepthWire.xcodeproj`, build, and **copy the app to /Applications before launching**: macOS only activates camera extensions from there.

## Use

1. Open DepthWire on the Mac. Approve the camera extension when macOS asks (System Settings → General → Login Items & Extensions → Camera Extensions).
2. Open DepthWire on the iPhone. It starts streaming straight away; both devices need to be on the same network.
3. The Mac window shows "Connected". Pick the **DepthWire** camera in any app.

If the Mac shows "Bonjour blocked", allow DepthWire under Privacy & Security → Local Network.

## Roadmap

- [ ] One calibration view on the Mac: raw depth, range, crop, and a one-button "record the empty room"
- [ ] Raw depth output for TouchDesigner, Resolume and Unity (Syphon first, then NDI)
- [ ] Signed, notarized Mac download
- [ ] iPhone app on the App Store
- [ ] Remember all Mac settings between launches

## License

[MIT](LICENSE)
