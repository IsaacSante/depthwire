# Set up the room

About 15 minutes, once the apps are installed and talking to each other.

## 1. Place the phone

- **Landscape, on a tripod, and don't touch it afterwards.** Calibration only holds while the phone stays put.
- **Low and looking up slightly** works well: about 2 ft off the floor, a few feet in front of the projection wall, facing the people.
- **Know the range.** The LiDAR sees to roughly 5 m (16 ft). People beyond that don't register.
- **Light doesn't matter.** LiDAR works in a dark room, and the projector's picture on the wall isn't mistaken for movement.

## 2. Calibrate the empty room

In DepthWire on the Mac:

1. Clear the space. Nobody in the phone's view.
2. Press **Calibrate** and step out for 3 seconds.
3. Walk back in. You should appear on a black background, with the room gone.

Do it again whenever the phone or the furniture moves. If you change rooms, press **Reset calibration** first.

## 3. Choose the area

- **Nearest / Farthest:** set these to where people will actually stand. Anything outside is ignored, so a doorway or a back wall stops triggering things.
- **More options → crop:** zoom in or shift the picture to keep one part of the room.

The small corner view shows everything the phone sees. Red stripes are too near, blue stripes too far, grey stripes are the hidden room, and the white outline is the part your visuals get.

## 4. Set the output

- **Grayscale** for feeding visuals: white is near, dark is far.
- **Size:** match your project's resolution.
- **Flip left ↔ right** if the picture should act like a mirror for people facing the wall.

## Tips from the first install

- **Mark the floor.** A line of tape where the active area starts saves you explaining it all night.
- **Keep a little distance from the wall.** Right up against the picture, people cast the biggest shadows.
- **If the picture trails behind people,** open Advanced and lower Steadiness.
- **If someone standing still slowly fades out,** open Advanced and turn off "Let the recorded room adapt to slow changes".
