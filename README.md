# DepthWire

Turn an iPhone's LiDAR scanner into a depth camera for your Mac.

DepthWire is two small apps that work together:

| App | Folder | What it does |
|---|---|---|
| **DepthWire** (iPhone) | [`ios/`](ios) | Reads depth from the LiDAR scanner and streams it to your Mac over Wi-Fi, Ethernet or USB. |
| **DepthWire for Mac** | [`mac/`](mac) | Receives the depth, hides the empty room so only people show, and publishes the result as a **virtual camera** called "DepthWire" that any app can pick: TouchDesigner, OBS, Zoom, QuickTime, Unity. |

It was built for an interactive projection install where a Kinect or Orbbec wasn't available. A phone on a tripod did the job.

> **Status: early.** Both apps work and build from this repo. There are no downloads yet: a signed Mac app, the iPhone app on the App Store, and raw depth output are still to come. See [Roadmap](#roadmap).

## How it works

```
iPhone                                   Mac
LiDAR depth (up to 320×240)              DepthWire for Mac
  → rotate upright                         → noise filter, steadiness
  → [depth mm | confidence | person mask]  → hide the calibrated empty room
  → LZ4 → TCP (Bonjour _depthwire._tcp)    → keep the chosen distances and crop
                                           → Rainbow or Grayscale → virtual camera "DepthWire"
```

- **Depth** is sent as 16-bit millimetres, so the Mac gets real distances, not a picture of them.
- **Lens and gravity** travel with every frame, so the Mac can place each pixel in the room.
- **Works in the dark.** LiDAR doesn't need light, and a projector's picture on the wall doesn't read as movement.
- **Wired or wireless.** Wi-Fi works out of the box. For long shows, a USB-C Ethernet adapter on each end is steadier. Both apps show which one is in use.

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

1. Open DepthWire on the Mac. Approve the camera extension when macOS asks (System Settings → General → Login Items & Extensions → Camera Extensions). If the window still says "Waiting for camera extension" afterwards, quit and reopen the app.
2. Open DepthWire on the iPhone, on the same Wi-Fi as the Mac or joined to it by a cable. It starts sending straight away.
3. The banner at the top of the Mac window turns green: "Receiving depth from iPhone", with Wi-Fi or cable and the frame rate.
4. Pick the **DepthWire** camera in any app.

If the Mac says "Bonjour blocked", allow DepthWire under Privacy & Security → Local Network.

### Setting it up for a room

The Mac window walks through it:

- **1A Calibrate.** Press Calibrate and step out of view for 3 seconds. DepthWire learns the empty room and from then on shows only people and things that weren't there. The calibration is saved between launches.
- **1B Reset calibration.** Forgets it, for when the phone moves or you change rooms.
- **2 Choose the area.** Nearest and Farthest: anything outside that distance is left out. More options has a crop (zoom, left/right, up/down).
- **3 Set the output.** Rainbow or Grayscale, the picture size (16:9, 4:3 or square, up to 1920×1080), and flips left-right and up-down.

A corner view shows everything the phone sees, with what is too near, too far or hidden striped. Other apps never see it.

### In TouchDesigner

Add a **Video Device In TOP** and choose DepthWire. Set Colors to **Grayscale** in DepthWire: brightness is then distance, white at Nearest and dark at Farthest, with black for nothing. With the room calibrated, people are grey on black, which works directly as a mask or a depth map.

```
distance = Farthest − brightness × (Farthest − Nearest)
```

A virtual camera is 8-bit, so that is 256 steps across your range (about 2 cm over 5 m). Full-precision depth is on the roadmap. If movement leaves a trail, lower Steadiness under Advanced.

## Roadmap

- [ ] Raw 16-bit depth output for TouchDesigner, Resolume and Unity (Syphon first, then NDI)
- [ ] Signed, notarized Mac download
- [ ] iPhone app on the App Store
- [ ] Reconnect to the camera extension without restarting after first approval

## License

[MIT](LICENSE)
