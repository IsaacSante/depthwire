# DepthWire

**Make interactive installs with the phone you already have.**

DepthWire is a toolkit for building installations that react to people, using an iPhone's LiDAR in place of a Kinect or an Orbbec. It covers the whole chain: the apps, the gear, setting up a room, and starting points for visuals.

```
iPhone (LiDAR)  →  Mac (DepthWire)  →  TouchDesigner or any app  →  projector
```

It came out of a real install: a phone on a tripod, a laptop, a used projector, and a wall that moved when people did.

## Download

| | |
|---|---|
| **Mac app** | **[Download DepthWire for Mac](https://github.com/IsaacSante/depthwire/releases)** (macOS 14 or later) |
| **iPhone app** | Coming to the App Store. Until then, [build it from this repo](#build-from-source). |

You need both: the iPhone sends the depth, the Mac receives it.

## The toolkit

| Step | | What's there |
|---|---|---|
| 1 | **[What you need](guide/gear.md)** | The gear list: phone, Mac, projector, and the adapters and cable for long shows, with models and prices. |
| 2 | **[Get the apps talking](#get-started)** | Install both apps and see depth arrive. Four steps. |
| 3 | **[Set up the room](guide/room-setup.md)** | Where to put the phone, calibrating the empty room, choosing the area. |
| 4 | **[Make visuals](touchdesigner/)** | TouchDesigner starters you can paste in and build on. |
| 5 | **[Run a show](guide/run-a-show.md)** | Wi-Fi or cable, keeping the phone alive all night, and a checklist before the doors open. |

## Get started

You need an iPhone with LiDAR: an iPhone 12 Pro or any later Pro model.

1. **Mac:** open the download and drag DepthWire into Applications. Open it, and approve its camera when macOS asks (System Settings → General → Login Items & Extensions → Camera Extensions).
2. **iPhone:** open DepthWire, on the same Wi-Fi as your Mac. It starts sending by itself.
3. **Mac:** the banner at the top turns green, "Receiving depth from iPhone".
4. **Any app:** choose **DepthWire** as the camera.

In TouchDesigner that's a **Video Device In TOP** with DepthWire picked. Set Colors to **Grayscale** in DepthWire, and you get people in grey on black: white is near, dark is far.

## Troubleshooting

- **"No signal from your iPhone".** Open DepthWire on the phone and keep it on screen. Both devices must be on the same Wi-Fi, or joined by a cable.
- **"Waiting for camera extension"** after you approved it. Quit DepthWire on the Mac and open it again.
- **"Bonjour blocked".** Allow DepthWire under System Settings → Privacy & Security → Local Network.
- **Movement leaves a trail.** Open Advanced and lower Steadiness.

More in [Run a show](guide/run-a-show.md).

---

## Build from source

For developers. You need a recent Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an Apple Developer account. A free account can build the iPhone app; the Mac app contains a camera extension, which needs a paid one.

```bash
cp Config/Signing.example.xcconfig Config/Signing.xcconfig
```

Put your Team ID and a bundle prefix you own in `Config/Signing.xcconfig`. It is never committed. Then:

```bash
cd ios && xcodegen generate
```

```bash
cd mac && xcodegen generate
```

Open `ios/DepthWire.xcodeproj` and run it on your phone. Open `mac/DepthWire.xcodeproj`, build, and copy the app to /Applications before launching: macOS only activates camera extensions from there.

## What's in the repo

| Folder | What's in it |
|---|---|
| [`guide/`](guide) | The gear list, room setup and show notes. |
| [`touchdesigner/`](touchdesigner) | Starter scripts for visuals. |
| [`ios/`](ios) | The iPhone app: reads LiDAR depth and sends it. |
| [`mac/`](mac) | The Mac app and its camera extension. |
| [`Shared/`](Shared) | The wire format, one file compiled into both apps. |

How the apps work, briefly:

- The phone sends 16-bit depth in millimetres, up to 320×240, LZ4-compressed over TCP. The Mac finds it with Bonjour (`_depthwire._tcp`).
- Each frame also carries the lens and which way is down, so the Mac can place every pixel in the room.
- The Mac hides the calibrated room, keeps the chosen distances, colours the result and feeds it to a virtual camera.
- A virtual camera is 8-bit. In Grayscale that is 256 steps across your range: `distance = Farthest − brightness × (Farthest − Nearest)`.

## Roadmap

- [x] Mac download
- [ ] iPhone app on the App Store
- [ ] Full-precision depth output for TouchDesigner, Resolume and Unity
- [ ] More TouchDesigner starters
- [ ] No restart needed after approving the camera

## License

[MIT](LICENSE). Free for anything, including commercial work.
