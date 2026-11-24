<h1 align="center">DepthWire</h1>

<p align="center"><b>Make interactive installs with the phone you already have.</b><br>
An iPhone's LiDAR instead of a Kinect: the apps, the gear, the room setup and the visuals.</p>

<p align="center">
  <img src="media/phone.gif" width="250" alt="An iPhone on a tripod streaming depth to a laptop">
  <img src="media/people.gif" width="250" alt="A cat walking past, shown as a clean shape on the laptop">
  <img src="media/install-loop.gif" width="250" alt="A person in front of a projection that reacts to them">
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

<table><tr>
<td width="270"><img src="media/phone.gif" width="250" alt="The iPhone app streaming on a tripod"></td>
<td>

1. **Mac:** install [DepthWire for Mac](https://github.com/IsaacSante/depthwire/releases) and approve its camera.
2. **iPhone:** open DepthWire on the same Wi-Fi.
3. The Mac shows a green **Receiving depth** banner.
4. Pick **DepthWire** as the camera in any app.

The iPhone app isn't on the App Store yet. For now, [build it with Xcode](docs/development.md).

</td>
</tr></table>

## 3 · Set up the room

<p align="center"><img src="media/app-calibrate.gif" width="760" alt="DepthWire for Mac: the countdown, calibrating, the room disappearing, then a person walking in as the only thing visible"></p>

1. **Place the phone** on the tripod, low, facing the people. Don't move it again.
2. **Calibrate.** Press the button and step out for 3 seconds. The room disappears.
3. **Choose the area.** Set how near and how far to look.

It works in the dark.

→ [Room setup guide](guide/room-setup.md)

## 4 · Make visuals

<table><tr>
<td width="270"><img src="media/people.gif" width="250" alt="Only what moves shows up: a cat as a depth shape"></td>
<td>

Only what wasn't in the empty room shows up: people, or a cat.

In **TouchDesigner**, add a Video Device In TOP and pick DepthWire. You get grey shapes on black: white is near, dark is far.

Paste in a starter and build from there.

→ [TouchDesigner starters](touchdesigner/)

</td>
</tr></table>

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
