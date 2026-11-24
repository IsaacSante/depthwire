# DepthWire

Use your iPhone's LiDAR as a depth camera on your Mac. No Kinect needed.

Your phone streams depth to your Mac, and it shows up as a camera called **DepthWire** in TouchDesigner, OBS, Zoom or any other app.

## Download

| | |
|---|---|
| **Mac app** | **[Download DepthWire for Mac](https://github.com/IsaacSante/depthwire/releases)** (macOS 14 or later) |
| **iPhone app** | Coming to the App Store. Until then, [build it from this repo](#build-from-source). |

You need both: the iPhone app sends the depth, the Mac app receives it.
The iPhone must have LiDAR: an iPhone 12 Pro or any later Pro model.

## Get started

1. **Mac:** open the download and drag DepthWire into Applications. Open it, and approve its camera when macOS asks (System Settings → General → Login Items & Extensions → Camera Extensions).
2. **iPhone:** open DepthWire, on the same Wi-Fi as your Mac. It starts sending by itself.
3. **Mac:** the banner at the top turns green, "Receiving depth from iPhone".
4. **Any app:** choose **DepthWire** as the camera.

Something not working? See [Troubleshooting](#troubleshooting).

## Set it up for your room

In the Mac app:

1. **Calibrate.** Press Calibrate and step out of view for 3 seconds. DepthWire learns the empty room, then shows only people. It works in the dark.
2. **Choose the area.** Set the nearest and farthest distance to look at. Everything else is ignored.
3. **Set the output.** Rainbow or Grayscale, the picture size, and flip left-right or up-down.

## Use it in TouchDesigner

1. In DepthWire, set Colors to **Grayscale**.
2. In TouchDesigner, add a **Video Device In TOP** and pick **DepthWire**.

You get people in grey on black: white is near, dark is far. Use it as a mask or a depth map.

## Troubleshooting

- **"No signal from your iPhone".** Open DepthWire on the phone and keep it on screen. Both devices must be on the same Wi-Fi, or joined by a cable.
- **"Waiting for camera extension"** after you approved it. Quit DepthWire on the Mac and open it again.
- **"Bonjour blocked".** Allow DepthWire under System Settings → Privacy & Security → Local Network.
- **Movement leaves a trail.** Open Advanced and lower Steadiness.
- **Long shows.** Wi-Fi works, but a cable is steadier: a USB-C Ethernet adapter on the phone and one on the Mac.

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

## How it works

| Folder | What's in it |
|---|---|
| [`ios/`](ios) | The iPhone app: reads LiDAR depth and sends it. |
| [`mac/`](mac) | The Mac app and its camera extension. |
| [`Shared/`](Shared) | The wire format, one file compiled into both apps. |

- The phone sends 16-bit depth in millimetres, up to 320×240, LZ4-compressed over TCP. The Mac finds it with Bonjour (`_depthwire._tcp`).
- Each frame also carries the lens and which way is down, so the Mac can place every pixel in the room.
- The Mac hides the calibrated room, keeps the chosen distances, colours the result and feeds it to the virtual camera.
- A virtual camera is 8-bit. In Grayscale that is 256 steps across your range: `distance = Farthest − brightness × (Farthest − Nearest)`.

## Roadmap

- [x] Mac download
- [ ] iPhone app on the App Store
- [ ] Full-precision depth output for TouchDesigner, Resolume and Unity
- [ ] No restart needed after approving the camera

## License

[MIT](LICENSE). Free for anything, including commercial work.
