# U-Scan3D

Scan real objects with your iPhone and export print-ready STL files for your
Bambu Lab X1 Carbon (or any 3D printer).

**Scan → Reconstruct → Preview → Export STL → Slice → Print**

## Requirements

- iPhone Pro with LiDAR (iPhone 12 Pro or newer Pro model), iOS 17+
- No Mac needed to build — GitHub Actions compiles the app in the cloud

## How it works

| Stage | Tech |
|---|---|
| Guided capture | RealityKit `ObjectCaptureSession` — walk around the object, live point-cloud feedback, with prompts to flip the object (or scan another pass at a different height) once an orbit completes for full 360° coverage. An Object / Face-Bust / Full Body mode picker tailors the on-screen instructions and skips the flip prompt for people (reconstruction detail is `.reduced` either way — it's the only level available on-device on iOS). Full Body uses Object Capture's *area mode* on iOS 18+ (see below) |
| Full Body cut-out | Area-mode scans include the floor and surroundings. `PersonIsolator` finds the floor (the lowest height with a large area of level faces), slices just above it, and keeps the person-tall piece nearest the middle of the captured floor, plus small detached bits inside its outline. *Floor cut* and *Crop* sliders in the preview fix what the automatic cut gets wrong |
| Reconstruction | On-device `PhotogrammetrySession` — produces a textured USDZ mesh |
| Preview | SceneKit viewer with orbit/zoom controls, plus a *Print preview* toggle that renders the exact mesh that will be exported (after flat-base cut and repair, at print scale) |
| Mesh repair | Welds coincident vertices, finds boundary holes, and caps them so the export is watertight. Coplanar holes (like the flat-base cut) are capped together and nested by containment, so a mug's ring-shaped base gets an annulus, not two overlapping disks; caps are ear-clipped (holes bridged in), so L- and U-shaped outlines are covered exactly once. The result is validated (every edge shared by exactly two oppositely wound triangles, no upside-down cap faces) and the preview warns if it isn't |
| Flat base | Optional plane cut through the bottom of the scan (Sutherland-Hodgman triangle clipping), recapped by mesh repair, so it sits flush on the plate |
| Export | Binary STL or 3MF (Bambu's native format, written as a minimal OPC zip package), millimeters, Z-up, centered, resting on the plate, scaled to your chosen print size (defaults to real-world size) |
| Send to Printer | Uploads the exported file straight to a Bambu X1 Carbon over LAN via its FTPS server (port 990, `bblp` / the printer's Access Code) — no computer needed for the *transfer*. See the requirements and caveats below. |

**Storage:** a scan's captured photos (often hundreds of MB) are kept until
you approve the model. After a build, the preview shows **Looks good — free up
space** (deletes the photos) and **Rebuild**. Photos you never approve are
deleted automatically when the app launches more than 7 days after the scan.
If reconstruction fails, the photos are kept so you can tap **Try Again**;
scans that never produced a model are cleaned up the next time the app
launches.

**Ghosted flip scans:** a flipped pass sometimes comes out as two overlapping
copies because Apple's reconstruction misaligns it with the first pass. The
app records where each pass starts (`passes.json` in the scan folder), so
**Rebuild → Rebuild without flipped side** reconstructs from only the photos
taken before the first flip. It writes a new `model.usdz`; if the rebuild fails
or is cancelled, the previous model is kept.

**Full Body scans:** Object Capture's bounding box only fits around a
standing person from 2–3 m away, which is too far indoors. On iOS 18+,
Full Body skips the box and uses *area mode*: walk three slow loops about
1 m from the subject (low, middle, high), then the app cuts the person out
of the floor and surroundings. Full Body prints default to 150 mm, with a
warning below that size that ankles, wrists and fingers may be too thin. On
iOS 17 Full Body falls back to the box, so you'll have to stand well back.
Each scan records its mode in `scan.json`, so saved scans reopen with the
right processing, and the home list shows the scan type.

**Face detail:** on-device reconstruction is coarse over a whole body, so a
Full Body scan's preview offers **Add face detail from a Face / Bust scan**.
Scan the same person in Face / Bust mode (same hair and clothes, head held
the same way), then tap the nose tip, left ear and right ear on each scan.
`HeadSwap` makes a rough fit from those three points (Horn's quaternion
method), refines it with point-to-plane ICP between the two heads, cuts the
body just under the chin and the bust 4 cm lower, and seals each piece. The
two pieces overlap at the neck and are exported together as overlapping
solids, which the slicer merges; sewing two scans' edges together exactly
isn't reliable. The result (with the average gap between the heads) is
saved as a new scan (`model.obj`); both originals are kept. Raised arms or
long hair that crosses the neck cut will be sliced there too.

Exported STLs open directly in Bambu Studio. AirDrop or share them to your
computer, open in the Bambu Handy app, or send them to the printer directly
over Wi-Fi from the app.

**Caveat on "Send to Printer":** Bambu printers don't slice on-device — they
only print G-code. This feature stages the raw (unsliced) STL/3MF on the
printer's local storage over FTPS; it does **not** make the file printable by
itself. You still need to open it in Bambu Studio on a computer to slice it
(add supports, infill, etc.) before the printer can actually print it. Useful
mainly as a quick way to get the file physically onto the printer's storage;
not a full computer-free path to printing.

**Send to Printer requirements and known limitation:**

- Phone and printer on the same Wi-Fi; enter the printer's IP address and
  Access Code (printer: Settings > Network > LAN Only Mode). Recent Bambu
  firmware may also require **LAN Only Mode** and/or **Developer Mode** to be
  on before third-party apps can connect.
- The access code is stored in the iOS Keychain. The printer uses a
  self-signed certificate, so U-Scan3D trusts it on the first successful
  login and remembers it (trust on first use). If you reset or replace the
  printer, tap **Forget Printer** in printer settings.
- Exports are named from the scan date and size (e.g.
  `U-Scan3D-20260923-1430-100mm.stl`) so they never overwrite each other.
- **May not work yet:** the printer's FTPS server (vsftpd) requires the file
  transfer connection to reuse the login connection's TLS session. Apple's
  Network framework has no way to force that (per Apple DTS). The app enables
  session resumption and shares one TLS configuration across both
  connections, but if the printer still refuses, you'll see a specific
  "refused the file-transfer connection" error — send the file with Bambu
  Studio or Bambu Handy instead.

## Building without a Mac (zero cost)

1. Push this repo to **GitHub as a public repo**. Every push to `main` runs the
   *Build unsigned IPA* workflow on a free macOS runner.
2. Download the `UScan3D-unsigned` artifact from the run's **Actions** page —
   it contains `UScan3D.ipa`.
3. Install [AltStore](https://altstore.io) on your Windows PC (requires iTunes
   and iCloud from Apple's site, not the Microsoft Store versions).
4. Sideload the IPA to your iPhone with AltStore using a free Apple ID.
   - Free-account signatures last 7 days; AltStore auto-refreshes over Wi-Fi
     while your PC is on the same network.

CI also runs a **mesh-tests** job: `Tests/MeshTests/main.swift` is a plain
executable (no XCTest) compiled with `swiftc` together with the app's mesh
code. It builds a box, a 64-sided cylinder, L- and U-shaped extrusions, a
two-legged arch and a tube, applies a 10% flat-base cut, repairs it, and checks
the result is valid, has no upside-down cap faces, and that the cap area
matches the true cross-section within 1%. It also cuts a person out of a
synthetic room (floor, a wall bigger than the person, a table, debris, a
detached hand), and fits a lopsided "bust" placed on a "torso" by a known
rotation from landmarks up to ~1 cm off, checking ICP recovers the
placement within 3 mm and both pieces seal with a 4 cm neck overlap. To run
it on a Mac:

```sh
swiftc UScan3D/Triangle.swift UScan3D/MeshRepair.swift UScan3D/MeshCutter.swift UScan3D/PersonIsolator.swift UScan3D/HeadSwap.swift   Tests/MeshTests/main.swift -o meshtests && ./meshtests
```

The Xcode project itself is generated from [`project.yml`](project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — don't commit an
`.xcodeproj`; CI regenerates it every build. On a Mac, run
`brew install xcodegen && xcodegen generate` and open the generated project.

## Scanning tips

- Objects with matte, textured surfaces scan best. Shiny, transparent, or
  featureless objects confuse photogrammetry.
- Even, diffuse lighting; avoid harsh shadows.
- Orbit slowly at a steady distance. More angles = better mesh.
- Flipping works best on objects with detail on every side. Lay the object on
  its side rather than upside down, keep it in the same spot, and don't change
  the lighting. For flat-bottomed objects, skip the flip and use **Flat base**.
- For busts of people: have them sit still (~1–2 min) and orbit their head
  and shoulders.
- For full bodies: a helper holds the phone while the subject stands still
  for 2–4 minutes, arms slightly out, feet shoulder-width apart, nothing
  touching them. Fitted, matte, patterned clothing tracks best; tie back
  long hair.

## Roadmap

- [x] 3MF export (Bambu's native format)
- [x] Mesh repair: hole filling and watertight check before export
- [x] Flat-base cut option so scans sit flush on the plate
- [x] Multiple scan passes / flip-object support for full 360° geometry
- [x] Direct upload to the X1 Carbon over LAN (FTPS; see caveat above — MQTT print-trigger not implemented since the uploaded file isn't sliced anyway)
- [x] Face scan mode
- [x] Full Body scan mode (area mode + automatic cut-out)
- [x] Add face detail: swap a Full Body scan's head for a separate Face / Bust scan
