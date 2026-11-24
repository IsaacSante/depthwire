<h1 align="center">DepthWire</h1>

<p align="center"><b>Make interactive installs with the phone you already have.</b><br>
An iPhone's LiDAR instead of a Kinect: the apps, the gear, the room setup and the visuals.</p>

<p align="center">
  <img src="media/hero-apps.png" width="820" alt="DepthWire on a MacBook receiving depth from DepthWire on an iPhone">
</p>

<p align="center">
  <a href="https://github.com/IsaacSante/depthwire/releases"><img src="https://img.shields.io/badge/Download-DepthWire_for_Mac-2f6fed?style=for-the-badge&logo=apple&logoColor=white" alt="Download DepthWire for Mac"></a>
  <img src="https://img.shields.io/badge/iPhone_app-coming_to_the_App_Store-555555?style=for-the-badge&logo=apple&logoColor=white" alt="iPhone app coming to the App Store">
</p>

<p align="center"><img src="media/setup.svg" width="820" alt="iPhone to Mac to your visuals to a projector"></p>

---

## 1 · What you need

- **An iPhone with LiDAR** (12 Pro or any later Pro)
- **A Mac**
- **A tripod** for the phone
- **A projector**

That's it for Wi-Fi. For shows that run for hours, add two Ethernet adapters and a long cable, about $70 in all.

→ [The full gear list, with models and prices](guide/gear.md)

## 2 · Get the apps talking

<p align="center"><img src="media/iphone-mockup.png" width="620" alt="DepthWire on an iPhone in landscape: the depth picture, a green Sending to your Mac card, and a Stop button"></p>

<p align="center"><img src="media/mac-mockup.png" width="720" alt="DepthWire for Mac on a MacBook, with a green banner: Receiving depth from iPhone, over Wi-Fi"></p>

1. **Mac:** install [DepthWire for Mac](https://github.com/IsaacSante/depthwire/releases) and approve its camera.
2. **iPhone:** open DepthWire on the same Wi-Fi.
3. The Mac shows a green **Receiving depth** banner, and the room appears.
4. Pick **DepthWire** as the camera in any app.

The iPhone app isn't on the App Store yet. For now, [build it with Xcode](docs/development.md).

## 3 · Set up the room

Place the phone on the tripod, low, facing the people. Then calibrate:

<table>
<tr>
<td width="50%"><img src="media/calibrate-1.png" alt="DepthWire showing the whole room in depth, not yet calibrated"><br><b>1. Start.</b> The phone sees the whole room.</td>
<td width="50%"><img src="media/calibrate-2.png" alt="The countdown: Step out of view, 2"><br><b>2. Press Calibrate</b> and step out of view. You get 3 seconds.</td>
</tr>
<tr>
<td><img src="media/calibrate-3.png" alt="A red frame around the picture while DepthWire calibrates the empty room"><br><b>3. Wait for the red frame.</b> It learns the empty room in about a second.</td>
<td><img src="media/calibrate-4.png" alt="A person shown as a clean shape on black, the room hidden"><br><b>4. Walk in.</b> The room is gone. Only you show up.</td>
</tr>
</table>

Then set how near and how far to look. It works in the dark.

→ [Watch the whole flow](media/app-calibrate.gif) · [Room setup guide](guide/room-setup.md)

## 4 · Make visuals

<p align="center"><img src="media/depth-output.png" width="620" alt="What other apps get from DepthWire: a person as a grey shape on black"></p>

This is what your visuals get: only what wasn't in the empty room. White is near, dark is far.

In **TouchDesigner**, add a Video Device In TOP and pick DepthWire. Paste in a starter and build from there.

→ [TouchDesigner starters](touchdesigner/)

## 5 · Run a show

<table><tr>
<td width="270"><img src="media/install-loop.gif" width="250" alt="The install: a projection reacting to a person"></td>
<td>

- **Use a cable** for anything that runs for hours.
- **Keep the phone charging** through its adapter.
- **Calibrate with the room empty** before the doors open.
- **Walk the whole area** and watch the edges.

→ [Show checklist and fixes](guide/run-a-show.md)

</td>
</tr></table>

---

<p align="center">
  <a href="docs/development.md">Build from source</a> ·
  <a href="guide/run-a-show.md#if-it-stops">Troubleshooting</a> ·
  <a href="LICENSE">MIT license</a>, free for anything
</p>
