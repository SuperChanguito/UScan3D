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
| Guided capture | RealityKit `ObjectCaptureSession` — walk around the object, live point-cloud feedback, with prompts to flip the object (or scan another pass at a different height) once an orbit completes for full 360° coverage. An Object/Face-Bust mode picker tailors the on-screen instructions and skips the flip prompt for people (reconstruction detail is `.reduced` either way — it's the only level available on-device on iOS) |
| Reconstruction | On-device `PhotogrammetrySession` — produces a textured USDZ mesh |
| Preview | SceneKit viewer with orbit/zoom controls, plus a *Print preview* toggle that renders the exact mesh that will be exported (after flat-base cut and repair, at print scale) |
| Mesh repair | Welds coincident vertices, finds boundary holes, and caps them so the export is watertight. Coplanar holes (like the flat-base cut) are capped together and nested by containment, so a mug's ring-shaped base gets an annulus, not two overlapping disks; caps are ear-clipped (holes bridged in), so L- and U-shaped outlines are covered exactly once. The result is validated (every edge shared by exactly two oppositely wound triangles, no upside-down cap faces) and the preview warns if it isn't |
| Flat base | Optional plane cut through the bottom of the scan (Sutherland-Hodgman triangle clipping), recapped by mesh repair, so it sits flush on the plate |
| Export | Binary STL or 3MF (Bambu's native format, written as a minimal OPC zip package), millimeters, Z-up, centered, resting on the plate, scaled to your chosen print size (defaults to real-world size) |
| Send to Printer | Uploads the exported file straight to a Bambu X1 Carbon over LAN via its FTPS server (port 990, `bblp` / the printer's Access Code) — no computer needed for the *transfer*. See the requirements and caveats below. |

**Storage:** a scan's captured photos (often hundreds of MB) are deleted once
its 3D model has been built successfully — only the model and your exports
are kept. If reconstruction fails, the photos are kept so you can tap
**Try Again**; scans that never produced a model are cleaned up the next time
the app launches.

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
matches the true cross-section within 1%. To run it on a Mac:

```sh
swiftc UScan3D/Triangle.swift UScan3D/MeshRepair.swift UScan3D/MeshCutter.swift   Tests/MeshTests/main.swift -o meshtests && ./meshtests
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
- For busts of people: have them sit still (~1–2 min) and orbit their head
  and shoulders.

## Roadmap

- [x] 3MF export (Bambu's native format)
- [x] Mesh repair: hole filling and watertight check before export
- [x] Flat-base cut option so scans sit flush on the plate
- [x] Multiple scan passes / flip-object support for full 360° geometry
- [x] Direct upload to the X1 Carbon over LAN (FTPS; see caveat above — MQTT print-trigger not implemented since the uploaded file isn't sliced anyway)
- [x] Face scan mode
