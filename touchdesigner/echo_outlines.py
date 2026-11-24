# Echo outlines: a glowing outline of your body that expands outward and shifts colour,
# leaving a tunnel of rings behind you.
#
# How to use:
#   1. In DepthWire, calibrate the room and set Colors to Grayscale.
#   2. In TouchDesigner, add a Video Device In TOP and pick DepthWire.
#   3. Paste this into a Text DAT, set the first line to that TOP's name,
#      then right-click the DAT and choose Run Script.
#   4. Look at the 'out' TOP.
#
# Safe to run again: it replaces the operators it made last time.

src = op('videodevin1')              # your DepthWire Video Device In TOP
p = src.parent()

def make(kind, name, col, row=0):
    if p.op(name): p.op(name).destroy()
    o = p.create(kind, name)
    o.nodeX = src.nodeX + col * 200
    o.nodeY = src.nodeY + row * 160
    return o

edge = make(edgeTOP,      'outline', 1)      # just the outline of the body
fb   = make(feedbackTOP,  'echo',    1, -1)  # the last frame
grow = make(transformTOP, 'grow',    2, -1)  # push it outward
hue  = make(hsvadjustTOP, 'shift',   3, -1)  # rotate its colour
fade = make(levelTOP,     'fade',    4, -1)  # let it die away
out  = make(compositeTOP, 'out',     5)      # outline + echoes

edge.setInputs([src])
fb.setInputs([edge])
grow.setInputs([fb])
hue.setInputs([grow])
fade.setInputs([hue])
out.setInputs([edge, fade])

fb.par.top = out                     # close the loop
out.par.operand = 'add'
grow.par.sx = 1.03                   # how fast the rings expand (1.01 slow, 1.08 fast, below 1 shrinks)
grow.par.sy = 1.03
hue.par.hueoffset = 12               # colour change per echo
hue.par.saturationmult = 1.5
fade.par.opacity = 0.93              # closer to 1 = more rings
edge.par.strength = 4
