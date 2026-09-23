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
| Guided capture | RealityKit `ObjectCaptureSession` — walk around the object, live point-cloud feedback |
| Reconstruction | On-device `PhotogrammetrySession` — produces a textured USDZ mesh |
| Preview | SceneKit viewer with orbit/zoom controls |
| Mesh repair | Welds coincident vertices, finds boundary holes, caps them with a triangle fan so the export is watertight |
| Flat base | Optional plane cut through the bottom of the scan (Sutherland-Hodgman triangle clipping), recapped by mesh repair, so it sits flush on the plate |
| Export | Custom binary STL writer (ModelIO mesh extraction): millimeters, Z-up, centered, resting on the plate, scaled to your chosen print size (defaults to real-world size) |

Exported STLs open directly in Bambu Studio. AirDrop or share them to your
computer, or open in the Bambu Handy app.

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

- [ ] 3MF export (Bambu's native format)
- [x] Mesh repair: hole filling and watertight check before export
- [x] Flat-base cut option so scans sit flush on the plate
- [ ] Multiple scan passes / flip-object support for full 360° geometry
- [ ] Direct upload to the X1 Carbon over LAN (FTP/MQTT)
- [ ] Face scan mode
