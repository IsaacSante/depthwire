# TouchDesigner starters

Small scripts that build a working network from the DepthWire camera. Each one is short enough to read and rebuild by hand.

## Before you start

1. In DepthWire on the Mac, **calibrate** the room and set Colors to **Grayscale**.
2. In TouchDesigner, add a **Video Device In TOP** and pick **DepthWire**.

You now have people in grey on black: white is near, dark is far.

## Running a starter

Paste the script into a **Text DAT**, set its first line to the name of your Video Device In TOP, then right-click the DAT and choose **Run Script**.

| Starter | What it makes |
|---|---|
| [`echo_outlines.py`](echo_outlines.py) | A glowing outline of your body that expands outward and shifts colour, leaving a tunnel of rings. |

## Building your own

Useful first steps from the depth picture:

- **A mask of people:** Threshold TOP (anything not black is a person), then a small Blur TOP.
- **Colour by distance:** Lookup TOP with a Ramp TOP as its second input.
- **How close is someone:** Analyze TOP (Maximum) into a TOP to CHOP.
- **Where people are:** Blob Track TOP on the mask.
- **Real distances:** `distance = Farthest − brightness × (Farthest − Nearest)`, using the two distances set in DepthWire.
