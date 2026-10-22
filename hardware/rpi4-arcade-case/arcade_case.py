"""RetroArch-PI mini arcade cabinet for the Raspberry Pi 4 (Fusion API script).

Run inside Fusion (Scripts and Add-Ins, or the Fusion MCP "script" call). It creates a new
direct-modelling design, builds every part, checks the parts against reference models of
the Pi 4, LCD, fan and switch, and exports STEP / 3MF / STL into OUT.

All dimensions are in mm (the Fusion API works in cm: see P() and mm()).
Frame: X = depth (0 = front of the control panel, + to the back), Y = up, Z = width
(0 = inner face of the left side, + to the right). The side profile lies in the XY plane.

Printing (Snapmaker U1, 4 colours): black body, yellow trim, red and white art. Each part
that has more than one colour is one STEP/3MF with one body per colour.
"""
import adsk.core
import adsk.fusion
import math
import os

OUT = r'C:\RetroArch_PI\hardware\rpi4-arcade-case'

# ---- Parameters (mm) ---------------------------------------------------------------
WALL = 2.5            # core walls
SIDE = 3.0            # side panels
W_IN = 90.0           # inner width (Pi 4 long side + port overhang)

# Side profile, clockwise (interior on the right of travel); the last edge is the open bottom.
PROFILE = [(8, 0), (8, 46), (0, 46), (0, 58), (42, 63), (42, 70), (56, 128),
           (34, 132), (30, 165), (74, 165), (88, 125), (88, 0)]

# LCD: ST7789V 2.4" 240x320, mounted landscape. Panel 60.26 x 42.72, active 48.96 x 36.72.
LCD_ACTIVE_W, LCD_ACTIVE_H = 48.96, 36.72
LCD_GLASS_W, LCD_GLASS_H = 60.26, 42.72
LCD_MOD_H = 44.0      # module height across the rails (largest of PCB and glass)
LCD_MOD_T = 4.3       # glass front to PCB back (components on the back excluded)
LCD_MOD_W = 71.0      # only used by the reference model
LCD_Z = W_IN / 2      # screen centre across the width

MARQ_H, MARQ_W, MARQ_T = 25.0, 86.0, 2.5
MARQ_TEXT = 'RETROARCH-PI'

BTN_S, BTN_Z = 24.0, 68.0     # power button: distance along the deck, position across
JOY_S, JOY_Z = 24.0, 24.0     # decorative joystick

FAN = 30.0
FAN_HOLES = 24.0
FAN_Y, FAN_Z = 56.0, 45.0     # fan centre on the back wall

TRAY_T = 3.0
STANDOFF_H = 7.0              # Pi PCB bottom at TRAY_T + STANDOFF_H
PI_BACK_X = 84.5              # Pi edge with USB-C/HDMI/audio (1 mm from the back wall)
PI_LEFT_Z = 2.0               # Pi edge with the SD card

TUBES = [(13.5, 16), (82.5, 32), (82.5, 120), (70.5, 159.5), (5.5, 51.5)]  # side screws
TUBE_R, PILOT_R = 3.0, 1.25   # M3 self-tapping into 2.5 mm pilots
TRAY_SCREWS = [(14, 12), (14, 78)]  # (X, Z), into the kick panel ledge

COLORS = {'Black': (30, 30, 32), 'Red': (210, 30, 40), 'White': (240, 240, 235),
          'Yellow': (250, 200, 20), 'Ref': (60, 140, 80), 'RefPCB': (20, 110, 50),
          'RefGlass': (40, 60, 120), 'RefMetal': (180, 180, 185)}

# ---- Helpers -----------------------------------------------------------------------
app = adsk.core.Application.get()
tbm = adsk.fusion.TemporaryBRepManager.get()


def mm(v):
    return v / 10.0


def P(x, y, z=0.0):
    return adsk.core.Point3D.create(mm(x), mm(y), mm(z))


def V(x, y, z=0.0):
    return adsk.core.Vector3D.create(x, y, z)


def box(x0, x1, y0, y1, z0, z1):
    c = P((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    obb = adsk.core.OrientedBoundingBox3D.create(c, V(1, 0, 0), V(0, 1, 0),
                                                 mm(x1 - x0), mm(y1 - y0), mm(z1 - z0))
    return tbm.createBox(obb)


def cyl(p1, p2, r1, r2=None):
    return tbm.createCylinderOrCone(P(*p1), mm(r1), P(*p2), mm(r1 if r2 is None else r2))


def zcyl(x, y, r, z0, z1):
    return cyl((x, y, z0), (x, y, z1), r)


def sphere(c, r):
    return tbm.createSphere(P(*c), mm(r))


def op(a, b, kind):
    t = {'cut': adsk.fusion.BooleanTypes.DifferenceBooleanType,
         'join': adsk.fusion.BooleanTypes.UnionBooleanType,
         'int': adsk.fusion.BooleanTypes.IntersectionBooleanType}[kind]
    if not tbm.booleanOperation(a, tbm.copy(b), t):
        raise RuntimeError('boolean %s failed' % kind)
    return a


def union(bodies):
    out = tbm.copy(bodies[0])
    for b in bodies[1:]:
        op(out, b, 'join')
    return out


def offset_poly(pts, ds):
    """Offset each edge of a clockwise polygon into the interior by ds[i] (mitred corners)."""
    n = len(pts)
    lines = []
    for i in range(n):
        p, q = pts[i], pts[(i + 1) % n]
        ux, uy = q[0] - p[0], q[1] - p[1]
        L = math.hypot(ux, uy)
        ux, uy = ux / L, uy / L
        lines.append(((p[0] + uy * ds[i], p[1] - ux * ds[i]), (ux, uy)))
    out = []
    for i in range(n):
        (p1, u1), (p2, u2) = lines[i - 1], lines[i]
        den = u1[0] * u2[1] - u1[1] * u2[0]
        t = ((p2[0] - p1[0]) * u2[1] - (p2[1] - p1[1]) * u2[0]) / den
        out.append((p1[0] + t * u1[0], p1[1] + t * u1[1]))
    return out


def prism(pts, z0, z1):
    """Extrude a closed XY polygon from z0 to z1 and return it as a temporary body."""
    root = app.activeProduct.rootComponent
    sk = root.sketches.add(root.xYConstructionPlane)
    sk.isComputeDeferred = True
    lines = sk.sketchCurves.sketchLines
    first = prev = None
    n = len(pts)
    for i in range(n):
        a = prev.endSketchPoint if prev else P(*pts[0])
        b = first.startSketchPoint if i == n - 1 else P(*pts[i + 1])
        ln = lines.addByTwoPoints(a, b)
        first = first or ln
        prev = ln
    sk.isComputeDeferred = False
    ext = root.features.extrudeFeatures
    inp = ext.createInput(sk.profiles.item(0), adsk.fusion.FeatureOperations.NewBodyFeatureOperation)
    inp.setOneSideExtent(adsk.fusion.DistanceExtentDefinition.create(
        adsk.core.ValueInput.createByReal(mm(z1 - z0))), adsk.fusion.ExtentDirections.PositiveExtentDirection)
    inp.startExtent = adsk.fusion.OffsetStartDefinition.create(adsk.core.ValueInput.createByReal(mm(z0)))
    f = ext.add(inp)
    body = tbm.copy(f.bodies.item(0))
    f.bodies.item(0).deleteMe()
    sk.deleteMe()
    return body


class Wall:
    """A straight wall of the profile: s along the outer face from p, n into the cabinet."""

    def __init__(self, p, q):
        self.p = p
        L = math.hypot(q[0] - p[0], q[1] - p[1])
        self.L = L
        self.d = ((q[0] - p[0]) / L, (q[1] - p[1]) / L)
        self.r = (self.d[1], -self.d[0])

    def pt(self, s, n):
        return (self.p[0] + s * self.d[0] + n * self.r[0], self.p[1] + s * self.d[1] + n * self.r[1])

    def box(self, s0, s1, n0, n1, z0, z1):
        c = self.pt((s0 + s1) / 2, (n0 + n1) / 2)
        obb = adsk.core.OrientedBoundingBox3D.create(
            P(c[0], c[1], (z0 + z1) / 2), V(self.d[0], self.d[1]), V(self.r[0], self.r[1]),
            mm(s1 - s0), mm(n1 - n0), mm(z1 - z0))
        return tbm.createBox(obb)

    def hooks(self, s_c, h, gap, post=2.5, lip=1.5, overlap=2.0, clr=0.3):
        """Two L-shaped rails that hold a plate of height h and thickness gap against the
        inner face; the plate slides in along Z. Returns XY polygons."""
        polys = []
        for sign in (-1, 1):
            e = s_c + sign * h / 2
            a, b, c = e + sign * (clr + post), e + sign * clr, e - sign * overlap
            n0, n1, n2 = WALL - 0.5, WALL + gap, WALL + gap + lip
            polys.append([self.pt(a, n0), self.pt(b, n0), self.pt(b, n1), self.pt(c, n1),
                          self.pt(c, n2), self.pt(a, n2)])
        return polys

    def frame(self, s, z, n=0.0):
        """Matrix: origin on the wall at (s, n, z), x = +Z, y = along the wall, z = outward."""
        o = self.pt(s, n)
        m = adsk.core.Matrix3D.create()
        m.setWithCoordinateSystem(P(o[0], o[1], z), V(0, 0, 1), V(self.d[0], self.d[1]),
                                  V(-self.r[0], -self.r[1]))
        return m


def mat(o, x=(1, 0, 0), y=(0, 1, 0), z=(0, 0, 1)):
    m = adsk.core.Matrix3D.create()
    m.setWithCoordinateSystem(P(*o), V(*x), V(*y), V(*z))
    return m


def chain(*ms):
    """chain(a, b, c) = a * b * c (c is applied first)."""
    out = adsk.core.Matrix3D.create()
    for m in reversed(ms):
        out.transformBy(m)
    return out


def inverse(m):
    i = m.copy()
    i.invert()
    return i


def placed(body, m):
    b = tbm.copy(body)
    tbm.transform(b, m)
    return b


# ---- Build -------------------------------------------------------------------------
def build():
    W = {}
    for i, name in enumerate(['kick', 'under', 'lip', 'deck', 'riser', 'screen', 'shelf',
                              'marquee', 'top', 'slope', 'back', 'bottom']):
        W[name] = Wall(PROFILE[i], PROFILE[(i + 1) % len(PROFILE)])
    n_edges = len(PROFILE)
    inner = offset_poly(PROFILE, [WALL] * (n_edges - 1) + [-1.0])
    trim_in = offset_poly(PROFILE, [2.0] * (n_edges - 1) + [-1.0])
    art_area = offset_poly(PROFILE, [4.0] * n_edges)

    parts = {}

    # Core: the profile walls plus the left side, open at the bottom and on the right.
    core = prism(PROFILE, -SIDE, W_IN)
    op(core, prism(inner, 0, W_IN + 1), 'cut')

    # The tray goes in from below with the Pi on it: its back tongue hooks into a groove in
    # the back wall, then two screws hold the front to a ledge on the kick panel. Nothing
    # else may sit under the Pi's footprint.
    feats = [zcyl(x, y, TUBE_R, 0, W_IN) for x, y in TUBES]
    feats += [box(10.5, 17.5, TRAY_T, TRAY_T + 4, 0, W_IN)]
    scr, mq, deck = W['screen'], W['marquee'], W['deck']
    lcd_sc = scr.L / 2
    mq_sc = mq.L / 2
    for poly in scr.hooks(lcd_sc, LCD_MOD_H, LCD_MOD_T + 0.4) + mq.hooks(mq_sc, MARQ_H, MARQ_T + 0.4):
        feats.append(prism(poly, 0, W_IN))
    for f in feats:
        op(core, f, 'join')
    op(core, prism(PROFILE, -SIDE - 1, W_IN), 'int')   # nothing pokes out of the outline

    cuts = [zcyl(x, y, PILOT_R, 10, W_IN + 1) for x, y in TUBES]
    for x, z in TRAY_SCREWS:
        cuts.append(cyl((x, TRAY_T - 0.1, z), (x, TRAY_T + 4.1, z), PILOT_R))
    cuts.append(box(85.3, 87.2, 1.3, 3.3, -1, W_IN + 1))              # groove for the tray tongue
    cuts.append(scr.box(lcd_sc - LCD_ACTIVE_H / 2 - 0.6, lcd_sc + LCD_ACTIVE_H / 2 + 0.6, -1, WALL + 0.1,
                        LCD_Z - LCD_ACTIVE_W / 2 - 0.5, LCD_Z + LCD_ACTIVE_W / 2 + 0.5))
    cuts.append(mq.box(mq_sc - MARQ_H / 2 + 2, mq_sc + MARQ_H / 2 - 2, -1, WALL + 0.1, 5, W_IN - 5))
    m_btn = deck.frame(BTN_S, BTN_Z)
    m_joy = deck.frame(JOY_S, JOY_Z)
    cuts.append(placed(cyl((0, 0, -4), (0, 0, 1), 12.2), m_btn))
    cuts.append(placed(cyl((0, 0, -0.6), (0, 0, 1), 12.3), m_joy))
    # Fan: four M3 holes and horizontal slots (print-friendly when the core lies on its side).
    for dy in (-FAN_HOLES / 2, FAN_HOLES / 2):
        for dz in (-FAN_HOLES / 2, FAN_HOLES / 2):
            cuts.append(cyl((84, FAN_Y + dy, FAN_Z + dz), (90, FAN_Y + dy, FAN_Z + dz), 1.65))
    for k in range(-3, 4):
        e = abs(4 * k) + 1.2
        half = math.sqrt(max(13.5 ** 2 - e ** 2, 0))
        cuts.append(box(84, 90, FAN_Y + 4 * k - 1.2, FAN_Y + 4 * k + 1.2, FAN_Z - half, FAN_Z + half))
    # Ports: USB-C, 2x micro-HDMI, audio at the back; SD card on the left (open at the bottom).
    pz = lambda x: PI_LEFT_Z + x
    px = lambda y: PI_BACK_X - y
    cuts.append(box(84, 90, -1, 20, pz(4), pz(60)))
    cuts.append(box(px(37), px(19), -1, 13, -SIDE - 1, 0.01))
    # Coin door on the kick panel: groove outline and two coin slots (air intake).
    g = box(7, 8.8, 10, 36, W_IN / 2 - 17, W_IN / 2 + 17)
    op(g, box(6, 9, 11, 35, W_IN / 2 - 16, W_IN / 2 + 16), 'cut')
    cuts += [g, box(7, 11, 21, 31, W_IN / 2 - 9, W_IN / 2 - 6.5), box(7, 11, 21, 31, W_IN / 2 + 6.5, W_IN / 2 + 9)]
    for c in cuts:
        op(core, c, 'cut')

    # Side art: yellow trim along the edge (open at the bottom), red/white/yellow stripes.
    def art(z0, z1):
        trim = prism(PROFILE, z0, z1)
        op(trim, prism(trim_in, z0 - 1, z1 + 1), 'cut')
        area = prism(art_area, z0 - 1, z1 + 1)
        ux, uy = math.cos(math.radians(55)), math.sin(math.radians(55))
        nx, ny = uy, -ux
        stripes = {}
        for name, x0, w in [('Red', 30, 9), ('White', 46, 5), ('Yellow', 58, 2.5)]:
            pts = [(x0 + sx * w / 2 * nx + t * ux, sx * w / 2 * ny + t * uy)
                   for sx, t in [(-1, -200), (1, -200), (1, 200), (-1, 200)]]
            s = prism(pts, z0, z1)
            op(s, area, 'int')
            stripes[name] = s
        op(stripes['Yellow'], trim, 'join')
        return {'Yellow': stripes['Yellow'], 'Red': stripes['Red'], 'White': stripes['White']}

    left_art = art(-SIDE, -SIDE + 0.6)
    for b in left_art.values():
        op(core, b, 'cut')
    sd = box(px(37), px(19), -1, 13, -SIDE - 1, 0.01)
    for b in left_art.values():
        op(b, sd, 'cut')
    # Print orientation: left side on the bed (art face down).
    parts['Core'] = (mat((0, 0, SIDE)), [('Core', core, 'Black')] +
                     [('Core_Art_' + k, b, k) for k, b in left_art.items()])

    # Right side: screws into the tubes, USB/Ethernet opening open at the bottom.
    right = prism(PROFILE, W_IN, W_IN + SIDE)
    right_art = art(W_IN + SIDE - 0.6, W_IN + SIDE)
    rcuts = [box(px(55), px(1), -1, 28.5, W_IN - 1, W_IN + SIDE + 1)]
    for x, y in TUBES:
        rcuts.append(zcyl(x, y, 1.7, W_IN - 1, W_IN + SIDE + 1))
        rcuts.append(cyl((x, y, W_IN + SIDE - 1.55), (x, y, W_IN + SIDE + 0.01), 1.7, 3.26))
    for c in rcuts:
        op(right, c, 'cut')
    for b in right_art.values():
        op(right, b, 'cut')
        for c in rcuts:
            op(b, c, 'cut')
    top_y = max(p[1] for p in PROFILE)
    parts['SideRight'] = (mat((0, top_y, W_IN + SIDE), (1, 0, 0), (0, -1, 0), (0, 0, -1)),   # art face down
                          [('SideRight', right, 'Black')] +
                          [('SideRight_Art_' + k, b, k) for k, b in right_art.items()])

    # Tray: Pi standoffs, vents, feet recesses; four countersunk M3 screws into the ledges.
    tray = box(10.7, 85.3, 0, TRAY_T, 0.2, W_IN - 0.2)
    holes = [(3.5, 3.5), (61.5, 3.5), (3.5, 52.5), (61.5, 52.5)]
    for hx, hy in holes:
        op(tray, cyl((px(hy), TRAY_T - 0.1, pz(hx)), (px(hy), TRAY_T + STANDOFF_H, pz(hx)), 3.0), 'join')
    for hx, hy in holes:
        op(tray, cyl((px(hy), TRAY_T + 1, pz(hx)), (px(hy), TRAY_T + STANDOFF_H + 1, pz(hx)), 1.1), 'cut')
    for z0, z1 in [(0.5, 5.0), (63.0, 89.5)]:                          # tongue (outside the port opening)
        op(tray, box(85.0, 86.9, 1.5, TRAY_T, z0, z1), 'join')
    for x, z in TRAY_SCREWS:
        op(tray, cyl((x, -1, z), (x, TRAY_T + 1, z), 1.7), 'cut')
        op(tray, cyl((x, -0.01, z), (x, 1.55, z), 3.26, 1.7), 'cut')
    for k in range(10):
        z = 12 + 5 * k
        op(tray, box(38, 66, -1, TRAY_T + 1, z, z + 2.5), 'cut')
    for x, z in [(24, 10), (24, 80), (74, 22), (74, 70)]:
        op(tray, cyl((x, -0.01, z), (x, 1.0, z), 5.2), 'cut')
    parts['Tray'] = (mat((0, W_IN, 0), (1, 0, 0), (0, 0, 1), (0, -1, 0)), [('Tray', tray, 'Black')])

    # Local-frame parts (z = outward from the deck / marquee face).
    mframe = mq.frame(mq_sc - MARQ_H / 2, (W_IN - MARQ_W) / 2, WALL)
    marquee = box(0, MARQ_W, 0, MARQ_H, -MARQ_T, 0)

    housing = cyl((0, 0, 0), (0, 0, 3.5), 15)
    op(housing, cyl((0, 0, -12.3), (0, 0, 0.01), 12), 'join')
    for c in [cyl((0, 0, -8.8), (0, 0, 3.6), 9.7), cyl((0, 0, 1.5), (0, 0, 3.6), 13.1),
              box(-6.15, 6.15, -6.15, 6.15, -10.3, -8.7)]:
        op(housing, c, 'cut')
    groove = cyl((0, 0, -4.2), (0, 0, -2.3), 12.5)
    op(groove, cyl((0, 0, -5), (0, 0, -1), 10.8), 'cut')
    op(housing, groove, 'cut')
    for sx in (-6.25, 6.25):
        for sy in (-2.5, 2.5):
            op(housing, cyl((sx, sy, -13), (sx, sy, -10.2), 0.8), 'cut')
    ring = cyl((0, 0, 1.5), (0, 0, 3.5), 12.95)
    op(ring, cyl((0, 0, 1), (0, 0, 4), 7.8), 'cut')
    cap = cyl((0, 0, -3.0), (0, 0, 1.5), 9.4)      # bottom rests on the switch plunger
    op(cap, cyl((0, 0, 1.4), (0, 0, 5.0), 7.5), 'join')
    dome = sphere((0, 0, -13), 19.5)
    op(dome, cyl((0, 0, 4.9), (0, 0, 7), 7.5), 'int')
    op(cap, dome, 'join')
    clip = cyl((0, 0, -4.0), (0, 0, -2.5), 15)
    op(clip, cyl((0, 0, -5), (0, 0, -1), 10.8), 'cut')
    op(clip, box(-9.5, 9.5, 0, 20, -5, -1), 'cut')

    stick = cyl((0, 0, -0.6), (0, 0, 1.4), 12)
    op(stick, cyl((0, 0, 1.3), (0, 0, 15.4), 3.5), 'join')
    op(stick, cyl((0, 0, 15.3), (0, 0, 21.4), 2), 'join')
    ball = sphere((0, 0, 21.4), 8)
    op(ball, box(-10, 10, -10, 10, 15.4, 40), 'int')       # flat bottom to print on
    op(ball, cyl((0, 0, 15.3), (0, 0, 21.6), 2.15), 'cut')

    # References (not printed): Pi 4, LCD, fan, switch.
    pcb_y = TRAY_T + STANDOFF_H
    ref = [('REF_Pi4_PCB', box(px(56), px(0), pcb_y, pcb_y + 1.5, pz(0), pz(85)), 'RefPCB')]
    top = pcb_y + 1.5
    for name, b in [('REF_Ethernet', box(px(53.75), px(37.75), top, top + 13.5, pz(65.5), pz(88.1))),
                    ('REF_USB_a', box(px(33.6), px(20.4), top, top + 16, pz(68), pz(87.1))),
                    ('REF_USB_b', box(px(15.6), px(2.4), top, top + 16, pz(68), pz(87.1))),
                    ('REF_USBC', box(px(7.3), px(-1), top, top + 3.2, pz(6.7), pz(15.7))),
                    ('REF_HDMI0', box(px(6.5), px(-0.5), top, top + 3.0, pz(22.5), pz(29.5))),
                    ('REF_HDMI1', box(px(6.5), px(-0.5), top, top + 3.0, pz(36), pz(43))),
                    ('REF_Audio', box(px(12.5), px(0), top, top + 6, pz(50.5), pz(56.5))),
                    ('REF_GPIO', box(px(55), px(50), top, top + 8.5, pz(7), pz(58))),
                    ('REF_SD', box(px(33.5), px(22.5), pcb_y - 1.5, pcb_y, pz(-2.5), pz(15)))]:
        ref.append((name, b, 'RefMetal'))
    ref.append(('REF_Fan30', box(85.5 - 10, 85.5, FAN_Y - FAN / 2, FAN_Y + FAN / 2,
                                 FAN_Z - FAN / 2, FAN_Z + FAN / 2), 'Ref'))
    lcd_m = scr.frame(lcd_sc, LCD_Z, WALL)
    # In the screen frame: x = across (Z), y = along the wall, z = outward (so -z goes inside).
    ref.append(('REF_LCD_glass', placed(box(-LCD_GLASS_W / 2, LCD_GLASS_W / 2, -LCD_GLASS_H / 2,
                                            LCD_GLASS_H / 2, -2.3, 0), lcd_m), 'RefGlass'))
    ref.append(('REF_LCD_pcb', placed(box(-LCD_MOD_W / 2, LCD_MOD_W / 2, -LCD_MOD_H / 2,
                                          LCD_MOD_H / 2, -LCD_MOD_T, -2.3), lcd_m), 'RefPCB'))
    sw = box(-6, 6, -6, 6, -10.3, -6.7)
    op(sw, cyl((0, 0, -6.8), (0, 0, -3.0), 1.75), 'join')
    ref.append(('REF_Switch12', placed(sw, m_btn), 'RefMetal'))

    # Parts built in a local frame: (frame, print matrix, bodies). The print matrix turns the
    # local frame into the print orientation (first layer at z = 0).
    flip = lambda zt: mat((0, 0, zt), (1, 0, 0), (0, -1, 0), (0, 0, -1))
    local = {
        'Marquee': (mframe, mat((0, MARQ_H, 0), (1, 0, 0), (0, -1, 0), (0, 0, -1)),
                    [('Marquee', marquee, 'White')]),
        'PowerButton': (m_btn, flip(3.5), [('Button_Housing', housing, 'Black'),
                                           ('Button_Ring', ring, 'Yellow'), ('Button_Clip', clip, 'Black')]),
        'ButtonCap': (m_btn, mat((0, 0, 3.0)), [('Button_Cap', cap, 'Red')]),
        'Joystick': (m_joy, mat((0, 0, 0.6)), [('Joystick_Stick', stick, 'Black')]),
        'JoystickBall': (m_joy, mat((0, 0, -15.4)), [('Joystick_Ball', ball, 'Red')]),
    }
    return parts, local, ref


def marquee_text(comp):
    """Sketch text on the marquee front (local z = 0), extruded 0.6 mm into the plate.
    Built in a scratch sketch of comp; returns a temporary body in the marquee's local frame."""
    sk = comp.sketches.add(comp.xYConstructionPlane)
    height = 12.0
    for _ in range(4):
        ti = sk.sketchTexts.createInput2(MARQ_TEXT, mm(height))
        ti.setAsMultiLine(P(MARQ_W / 2 - 100, 0), P(MARQ_W / 2 + 100, MARQ_H),
                          adsk.core.HorizontalAlignments.CenterHorizontalAlignment,
                          adsk.core.VerticalAlignments.MiddleVerticalAlignment, 0)
        ti.fontName = 'Impact'
        txt = sk.sketchTexts.add(ti)
        bb = txt.boundingBox
        width = (bb.maxPoint.x - bb.minPoint.x) * 10
        if width <= MARQ_W - 12:
            break
        txt.deleteMe()
        height *= (MARQ_W - 13) / width
    ext = comp.features.extrudeFeatures
    inp = ext.createInput(txt, adsk.fusion.FeatureOperations.NewBodyFeatureOperation)
    inp.setOneSideExtent(adsk.fusion.DistanceExtentDefinition.create(
        adsk.core.ValueInput.createByReal(mm(0.6))), adsk.fusion.ExtentDirections.PositiveExtentDirection)
    inp.startExtent = adsk.fusion.OffsetStartDefinition.create(adsk.core.ValueInput.createByReal(mm(-0.6)))
    f = ext.add(inp)
    bodies = [tbm.copy(f.bodies.item(i)) for i in range(f.bodies.count)]
    for i in range(f.bodies.count - 1, -1, -1):
        f.bodies.item(i).deleteMe()
    sk.deleteMe()
    return union(bodies), height, width


def appearances(design):
    lib = None
    for i in range(app.materialLibraries.count):
        if 'Appearance' in app.materialLibraries.item(i).name:
            lib = app.materialLibraries.item(i)
            break
    base = None
    for want in ('Plastic', ''):
        for i in range(lib.appearances.count):
            a = lib.appearances.item(i)
            if a.name.startswith(want) and a.appearanceProperties.itemById('opaque_albedo'):
                base = a
                break
        if base:
            break
    out = {}
    for name, (r, g, b) in COLORS.items():
        a = design.appearances.addByCopy(base, 'U1 ' + name)
        prop = adsk.core.ColorProperty.cast(a.appearanceProperties.itemById('opaque_albedo'))
        prop.value = adsk.core.Color.create(r, g, b, 255)
        out[name] = a
    return out


def run(_context):
    # Close the documents earlier runs of this script made; never touch any other.
    for i in range(app.documents.count - 1, -1, -1):
        d = app.documents.item(i)
        des = adsk.fusion.Design.cast(d.products.itemByProductType('DesignProductType'))
        if des and des.attributes.itemByName('retroopi', 'arcade_case'):
            d.close(False)
    doc = app.documents.add(adsk.core.DocumentTypes.FusionDesignDocumentType)
    design = adsk.fusion.Design.cast(app.activeProduct)
    design.designType = adsk.fusion.DesignTypes.DirectDesignType
    design.attributes.add('retroopi', 'arcade_case', '1')
    root = design.rootComponent
    look = appearances(design)

    parts, local, ref = build()
    comps = {}

    def add(comp, name, body, color):
        b = comp.bRepBodies.add(body)
        b.name = name
        b.appearance = look[color]
        return b

    text, th, tw = marquee_text(root)
    mq_bodies = local['Marquee'][2]
    op(mq_bodies[0][1], text, 'cut')
    mq_bodies.append(('Marquee_Text', text, 'Red'))
    print('marquee text: %.1f mm high, %.1f mm wide' % (th, tw))

    # Each component holds its bodies in print orientation; its occurrence puts them back in
    # the cabinet, shown Z-up (model X -> world Y, model Y -> world Z, model Z -> world X).
    world = mat((0, 0, 0), (0, 1, 0), (0, 0, 1), (1, 0, 0))
    placements = [(n, adsk.core.Matrix3D.create(), pm, b) for n, (pm, b) in parts.items()]
    placements += [(n, fm, pm, b) for n, (fm, pm, b) in local.items()]
    for cname, frame_m, print_m, bodies in placements:
        occ = root.occurrences.addNewComponent(chain(world, frame_m, inverse(print_m)))
        occ.component.name = cname
        comps[cname] = occ.component
        for name, body, color in bodies:
            add(occ.component, name, placed(body, print_m), color)
    occ = root.occurrences.addNewComponent(world)
    occ.component.name = 'Reference (not printed)'
    for name, body, color in ref:
        add(occ.component, name, body, color)

    # Self-test of the clash check below: two 10 mm cubes overlapping by half.
    t = box(0, 10, 0, 10, 0, 10)
    op(t, box(5, 15, 0, 10, 0, 10), 'int')
    print('clash self-test: %.1f mm3 (expect 500.0)' % (t.volume * 1000))

    # Fit check: every printed body against every reference body and every other part.
    world = []
    for o in root.allOccurrences:
        for b in o.bRepBodies:
            world.append((o.component.name, b.name, tbm.copy(b)))
    clashes = 0
    for i in range(len(world)):
        for j in range(i + 1, len(world)):
            ci, ni, bi = world[i]
            cj, nj, bj = world[j]
            if ci == cj:
                continue
            bb1, bb2 = bi.boundingBox, bj.boundingBox
            if not bb1.intersects(bb2):
                continue
            x = tbm.copy(bi)
            if tbm.booleanOperation(x, tbm.copy(bj), adsk.fusion.BooleanTypes.IntersectionBooleanType) \
                    and x.volume > 1e-4:
                clashes += 1
                print('CLASH %s/%s x %s/%s: %.1f mm3' % (ci, ni, cj, nj, x.volume * 1000))
    print('clashes: %d' % clashes)

    print('print size (component frame; first layer must be at z = 0):')
    for cname, comp in comps.items():
        bb = comp.boundingBox
        print('  %-14s %6.1f x %6.1f x %6.1f mm, z from %.2f' % (
            cname, (bb.maxPoint.x - bb.minPoint.x) * 10, (bb.maxPoint.y - bb.minPoint.y) * 10,
            (bb.maxPoint.z - bb.minPoint.z) * 10, bb.minPoint.z * 10))
    bb = root.boundingBox
    print('assembly %.1f x %.1f x %.1f mm (W x D x H)' % ((bb.maxPoint.x - bb.minPoint.x) * 10,
                                                        (bb.maxPoint.y - bb.minPoint.y) * 10,
                                                        (bb.maxPoint.z - bb.minPoint.z) * 10))

    # Exports.
    em = design.exportManager
    for sub in ('step', '3mf', 'stl'):
        os.makedirs(os.path.join(OUT, sub), exist_ok=True)
    # Every export below overwrites its own file; other files in these folders
    # (the user's slicer projects, e.g. stl/MainCabinet_V3.3mf) are left alone.
    for cname, comp in comps.items():
        em.execute(em.createSTEPExportOptions(os.path.join(OUT, 'step', cname + '.step'), comp))
        em.execute(em.createC3MFExportOptions(comp, os.path.join(OUT, '3mf', cname + '.3mf')))
        for b in comp.bRepBodies:
            o = em.createSTLExportOptions(b, os.path.join(OUT, 'stl', b.name + '.stl'))
            o.meshRefinement = adsk.fusion.MeshRefinementSettings.MeshRefinementHigh
            em.execute(o)
    em.execute(em.createSTEPExportOptions(os.path.join(OUT, 'step', 'Assembly_with_references.step')))
    em.execute(em.createFusionArchiveExportOptions(os.path.join(OUT, 'rpi4-arcade-case.f3d')))
    app.activeViewport.fit()
    print('exported to ' + OUT)
