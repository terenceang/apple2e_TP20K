# Tang Primer 20K Dock — base bumper

Open-top friction-fit tray for the dock PCB, so the board can sit on a table
without the underside pins scratching it.

- Source: `Tang_Primer_20K_Dock_3713.step`
- Output: `Tang_Primer_20K_Dock_Bumper.stl` (mm, Z up, watertight, 1856 tris, 7.6 cm³)
- Print: PLA, Bambu X1C, 0.4 nozzle, no supports needed (floor down, ~8 g, ~40 min)

## Dimensions (mm)

| Feature | Value |
|---|---|
| Outer footprint | 101.0 x 79.0 |
| Outer corner radius | 3.0 (vertical edges) |
| Height | 6.7 (−3.2 → +3.5, PCB bottom = 0) |
| Wall thickness above PCB | 3.05 |
| Floor | **open** — 1.3 thick ring, 5.2 wide, hole 90.6 x 68.6 (R0.8) |
| Pin clearance above table | 1.73 (part bottom −3.2, pin tips −1.47) |
| Support ledge width | 1.12 |
| Lip height above PCB | 3.5 |
| Friction interference | 0.05 / side |
| Top chamfer | 0.4 x 45° (all top edges, also acts as lead-in) |

## How it fits

The PCB drops in open-top-side-up: its outer ~1.15 mm rim lands on the ledge at
z = 0, the 3.5 mm lip pinches the board edge (full 1.6 mm thickness), and the
pins hanging below sit in the 1.9 mm deep pocket — open to the table through
the hole in the floor plate.

14 relief notches are cut where dock components overhang the PCB outline
(USB/connector housings on +X, −Y and +Y). Each notch starts at the real low
point of that component *inside the wall band*, not at the floor — so every
slot has a solid sill underneath it instead of running down to the floor:

| Side | Slot starts at z | Sill height |
|---|---|---|
| −Y (DC jack, RJ45, HDMI, USB-C x2) | 1.29 – 2.26 | 3.2 – 4.2 |
| +Y (FPC connectors) | 1.29 – 1.32 | 3.2 |
| +X (barrel jack) | 1.21 | 3.1 |
| +X (DIP switch legs) | −1.90 | 0 (full depth, pins hang there) |

Only the DIP-switch corner still cuts to the floor, because its legs hang
1.56 mm below the board right at the edge. Everything else keeps a 3 mm+
solid band above the floor.

### FPC slots (+Y edge)

The four FPC connectors (FPC40, FPC24, 2× FPC10) only overhang the board by
0.1–0.6 mm, so a simple clearance pocket leaves ~2.2 mm of wall in front of
their cable mouths and no cable could be inserted. Those four reliefs are
therefore cut **right through the outer wall** — open windows from z = 1.30 to
the rim, 23.9 / 16.5 / 9.0 / 9.0 mm wide, with a solid sill below and a
pillar between each pair. Windows, not pockets:

| Connector | x range of slot | Width |
|---|---|---|
| FPC40 | 8.6 – 32.5 | 23.9 |
| FPC24 | 41.0 – 57.5 | 16.5 |
| FPC10 (1) | 64.5 – 73.5 | 9.0 |
| FPC10 (2) | 76.5 – 85.5 | 9.0 |

The other edge connectors protrude far enough that their reliefs break through
the wall anyway (RJ45, barrel jack) or the remaining fin fell below the 2 mm
minimum and was opened up (DC jack, both USB-C, DIP switch), so they are
already pluggable.

### Open bottom

The floor plate is cut away in the middle (`Extrude18`, opening 2.2 … 92.8 ×
2.2 … 70.8, R0.8), so the board's underside is visible and readable straight
through the tray. What remains below `z = −1.9` is a 5.2 mm ring.

This changes nothing about the fit. The ledge the board rests on is a band
from 0.05 to 1.2 mm inside the board outline, and it is still solid all the way
down to `z = −1.9` — the hole starts 1 mm further in, so the ledge is fully
supported, not cantilevered. The pins still hang in free space and still stop
**1.73 mm above the table**, because the ring, not the floor, sets the part's
lowest plane.

Side effects, all good: the print drops to ~8 g / 7.6 cm³, the open bottom
means no bridging anywhere, and you can push the board out from below instead
of prying at the lip.

### Corners

The board's own corners are **R3.0** (its outline is a polyline through
`(3,0) … (0.88,0.88) … (0,3)`, every vertex 3.000 mm from `(3,3)`). The cavity
follows them rather than staying square:

| Profile | Radius | Centre |
|---|---|---|
| PCB corner | 3.00 | (3, 3) |
| Grip cavity | **2.95** = 3.00 − 0.05 | (3, 3) |
| Support ledge | **1.80** = 3.00 − 1.20 | (3, 3) |
| Outer edge | 3.00 | (0, 0) |

All three inner profiles are the board's outline offset inward by their
respective amount, so the 0.05 squeeze is uniform right around the corner —
no clearance gap and no deeper bite. The corner therefore grips like the
straight edges do, which is why the interference total rises from 22.3 to
23.5 mm³ (+1.2 mm³ ≈ 0.05 mm × 18.85 mm of corner arc × 1.59 mm).

With `R_OUT = 3` the corner wall is ~4.3 mm (thicker than the 3.05 mm sides,
because the outer radius is tighter than the board's). Set `R_OUT = 6` if you
want a constant 3.05 mm wall all the way round — the outer arc is then exactly
the cavity arc offset by the wall thickness.

## Verified

Fusion interference analysis vs the full 604-body assembly: 1 hit only — the
intended PCB squeeze (23.5 mm³ over z 0 → 1.59: 22.3 on the straight edges +
1.2 around the four corner arcs). No component collisions. Re-run after the
floor was opened: identical result, so the cut removed only material the board
never touched.

## Tuning

- **Too tight**: reduce interference to 0.02–0.03 / side.
- **Too loose**: raise to 0.08–0.10 / side.
- Bottom outer edges are sharp by design (flat on the bed); sand if desired.
