// Mesh repair regression tests. A plain executable (no XCTest) so CI can
// build it with swiftc alongside the app's mesh code:
//
//   swiftc UScan3D/Triangle.swift UScan3D/MeshRepair.swift UScan3D/MeshCutter.swift UScan3D/PersonIsolator.swift \
//     Tests/MeshTests/main.swift -o meshtests && ./meshtests
//
// Each closed test mesh (meters, Z-up) gets a 10% flat-base cut and is then
// repaired. The cap must be a valid closed surface, face down everywhere,
// and cover exactly the true cross-section (a cap that overlaps itself or
// covers the inside of a ring has too much area).

import Foundation
import simd

// MARK: - Test meshes

func vertex(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Float> {
    SIMD3<Float>(Float(x), Float(y), Float(z))
}

/// Outward-facing wall quad over the boundary edge a -> b (interior on the
/// left when seen from above).
func wall(_ a0: SIMD3<Float>, _ b0: SIMD3<Float>, _ b1: SIMD3<Float>, _ a1: SIMD3<Float>, into mesh: inout [Triangle]) {
    mesh.append(Triangle(a: a0, b: b0, c: b1))
    mesh.append(Triangle(a: a0, b: b1, c: a1))
}

/// Extrudes a footprint made of grid cells (each `cell` meters square) from
/// z = 0 to z = height. Grid-aligned so there are no T-junctions.
func gridPrism(_ cells: [(Int, Int)], cell: Double, height: Double) -> [Triangle] {
    let occupied = Set(cells.map { "\($0.0),\($0.1)" })
    func p(_ x: Int, _ y: Int, _ z: Double) -> SIMD3<Float> {
        vertex(Double(x) * cell, Double(y) * cell, z)
    }
    var mesh: [Triangle] = []
    for (x, y) in cells {
        mesh.append(Triangle(a: p(x, y, height), b: p(x + 1, y, height), c: p(x + 1, y + 1, height)))
        mesh.append(Triangle(a: p(x, y, height), b: p(x + 1, y + 1, height), c: p(x, y + 1, height)))
        mesh.append(Triangle(a: p(x, y, 0), b: p(x + 1, y + 1, 0), c: p(x + 1, y, 0)))
        mesh.append(Triangle(a: p(x, y, 0), b: p(x, y + 1, 0), c: p(x + 1, y + 1, 0)))
        // (edge start, edge end, neighbor across the edge), counter-clockwise.
        let edges = [
            ((x, y), (x + 1, y), (x, y - 1)),
            ((x + 1, y), (x + 1, y + 1), (x + 1, y)),
            ((x + 1, y + 1), (x, y + 1), (x, y + 1)),
            ((x, y + 1), (x, y), (x - 1, y)),
        ]
        for (a, b, neighbor) in edges where !occupied.contains("\(neighbor.0),\(neighbor.1)") {
            wall(p(a.0, a.1, 0), p(b.0, b.1, 0), p(b.0, b.1, height), p(a.0, a.1, height), into: &mesh)
        }
    }
    return mesh
}

func ring(radius: Double, sides: Int, z: Double) -> [SIMD3<Float>] {
    (0..<sides).map { i in
        let angle = 2 * Double.pi * Double(i) / Double(sides)
        return vertex(radius * cos(angle), radius * sin(angle), z)
    }
}

func cylinder(radius: Double, height: Double, sides: Int) -> [Triangle] {
    let bottom = ring(radius: radius, sides: sides, z: 0)
    let top = ring(radius: radius, sides: sides, z: height)
    let bottomCenter = vertex(0, 0, 0)
    let topCenter = vertex(0, 0, height)
    var mesh: [Triangle] = []
    for i in 0..<sides {
        let j = (i + 1) % sides
        mesh.append(Triangle(a: topCenter, b: top[i], c: top[j]))
        mesh.append(Triangle(a: bottomCenter, b: bottom[j], c: bottom[i]))
        wall(bottom[i], bottom[j], top[j], top[i], into: &mesh)
    }
    return mesh
}

func tube(innerRadius: Double, outerRadius: Double, height: Double, sides: Int) -> [Triangle] {
    let outerBottom = ring(radius: outerRadius, sides: sides, z: 0)
    let outerTop = ring(radius: outerRadius, sides: sides, z: height)
    let innerBottom = ring(radius: innerRadius, sides: sides, z: 0)
    let innerTop = ring(radius: innerRadius, sides: sides, z: height)
    var mesh: [Triangle] = []
    for i in 0..<sides {
        let j = (i + 1) % sides
        mesh.append(Triangle(a: outerTop[i], b: outerTop[j], c: innerTop[j]))
        mesh.append(Triangle(a: outerTop[i], b: innerTop[j], c: innerTop[i]))
        mesh.append(Triangle(a: outerBottom[i], b: innerBottom[j], c: outerBottom[j]))
        mesh.append(Triangle(a: outerBottom[i], b: innerBottom[i], c: innerBottom[j]))
        wall(outerBottom[i], outerBottom[j], outerTop[j], outerTop[i], into: &mesh)
        wall(innerBottom[j], innerBottom[i], innerTop[i], innerTop[j], into: &mesh)
    }
    return mesh
}

/// Rotates +90° about X, standing a z-extrusion up on its y side.
func standUp(_ mesh: [Triangle]) -> [Triangle] {
    func r(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3<Float>(v.x, -v.z, v.y) }
    return mesh.map { Triangle(a: r($0.a), b: r($0.b), c: r($0.c)) }
}

func regularPolygonArea(radius: Double, sides: Int) -> Double {
    0.5 * Double(sides) * radius * radius * sin(2 * Double.pi / Double(sides))
}

// MARK: - Run

let cell = 0.01
let height = 0.08
let cases: [(name: String, mesh: [Triangle], crossSection: Double)] = [
    ("box", gridPrism([(0, 0), (1, 0), (2, 0), (0, 1), (1, 1), (2, 1)], cell: cell, height: height), 6 * cell * cell),
    ("cylinder-64", cylinder(radius: 0.03, height: height, sides: 64), regularPolygonArea(radius: 0.03, sides: 64)),
    ("L-extrusion", gridPrism([(0, 0), (1, 0), (2, 0), (0, 1), (0, 2)], cell: cell, height: height), 5 * cell * cell),
    ("U-extrusion", gridPrism([(0, 0), (1, 0), (2, 0), (0, 1), (0, 2), (2, 1), (2, 2)], cell: cell, height: height), 7 * cell * cell),
    ("arch-two-legs", standUp(gridPrism([(0, 2), (1, 2), (2, 2), (0, 0), (0, 1), (2, 0), (2, 1)], cell: cell, height: 0.02)), 2 * cell * 0.02),
    ("tube", tube(innerRadius: 0.025, outerRadius: 0.035, height: height, sides: 64),
     regularPolygonArea(radius: 0.035, sides: 64) - regularPolygonArea(radius: 0.025, sides: 64)),
]

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

var failures = 0
print("shape            holes  capTris  cap cm2  true cm2   err %  upside  badEdges  warn  result")
for testCase in cases {
    let input = MeshRepair.repair(testCase.mesh)
    let result = MeshRepair.repair(MeshCutter.cutFlatBase(testCase.mesh, fraction: 0.10))

    var capArea = 0.0
    var upsideDown = 0
    for triangle in result.triangles.suffix(result.capTriangleCount) {
        let a = SIMD3<Double>(Double(triangle.a.x), Double(triangle.a.y), Double(triangle.a.z))
        let b = SIMD3<Double>(Double(triangle.b.x), Double(triangle.b.y), Double(triangle.b.z))
        let c = SIMD3<Double>(Double(triangle.c.x), Double(triangle.c.y), Double(triangle.c.z))
        let normal = simd_cross(b - a, c - a)
        capArea += simd_length(normal) / 2
        if normal.z > 1e-6 * simd_length(b - a) * simd_length(c - a) {
            upsideDown += 1
        }
    }
    let errorPercent = abs(capArea - testCase.crossSection) / testCase.crossSection * 100
    let passed = input.wasWatertight && input.isValid &&
        result.isValid && upsideDown == 0 && result.upsideDownCapFaces == 0 &&
        errorPercent < 1
    if !passed { failures += 1 }

    print(
        testCase.name.padding(toLength: 16, withPad: " ", startingAt: 0),
        pad("\(result.holesFilled)", 5),
        pad("\(result.capTriangleCount)", 8),
        pad(String(format: "%.3f", capArea * 1e4), 8),
        pad(String(format: "%.3f", testCase.crossSection * 1e4), 9),
        pad(String(format: "%.3f", errorPercent), 7),
        pad("\(upsideDown)", 7),
        pad("\(result.badEdgeCount)", 9),
        pad("\(result.warningCount)", 5),
        passed ? " PASS" : " FAIL")
}

// MARK: - Person isolation (Full Body area-mode scans)

/// Single-sided grid of `cell`-sized squares from `origin` along `u` and
/// `v`, facing u × v. Shares vertices along its edges so it welds to
/// neighbors built on the same grid.
func sheet(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, cols: Int, rows: Int) -> [Triangle] {
    var mesh: [Triangle] = []
    for i in 0..<cols {
        for j in 0..<rows {
            let p00 = origin + u * Float(i) + v * Float(j)
            let p10 = p00 + u
            let p11 = p00 + u + v
            let p01 = p00 + v
            mesh.append(Triangle(a: p00, b: p10, c: p11))
            mesh.append(Triangle(a: p00, b: p11, c: p01))
        }
    }
    return mesh
}

func translate(_ mesh: [Triangle], by offset: SIMD3<Float>) -> [Triangle] {
    mesh.map { Triangle(a: $0.a + offset, b: $0.b + offset, c: $0.c + offset) }
}

func bounds(_ mesh: [Triangle]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    for t in mesh {
        for p in [t.a, t.b, t.c] {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
    }
    return (lo, hi)
}

// A 3 m square room corner: floor at z = 0, a 2.5 m wall welded to the
// floor's +x edge (bigger than the person, so size alone would pick it), a
// table, a scrap of debris, a 1.7 m "person" in the middle and a detached
// "hand" beside them.
let step: Float = 0.25
let floorSheet = sheet(origin: vertex(-1.5, -1.5, 0), u: SIMD3(step, 0, 0), v: SIMD3(0, step, 0), cols: 12, rows: 12)
let wallSheet = sheet(origin: vertex(1.5, -1.5, 0), u: SIMD3(0, step, 0), v: SIMD3(0, 0, step), cols: 12, rows: 10)
let table = translate(gridPrism([(0, 0)], cell: 0.6, height: 0.75), by: vertex(-1.3, 0.5, 0))
let debris = translate(gridPrism([(0, 0)], cell: 0.1, height: 0.1), by: vertex(0.9, -1.1, 0.05))
let person = cylinder(radius: 0.2, height: 1.7, sides: 32)
let hand = translate(gridPrism([(0, 0)], cell: 0.06, height: 0.06), by: vertex(0.18, -0.03, 1.0))
let room = floorSheet + wallSheet + table + debris + person + hand

print("")
print("isolation        floor  person   minZ    maxZ   width  hand  valid  result")
for (name, settings) in [
    ("auto", PersonIsolator.Settings()),
    ("crop-0.5m", PersonIsolator.Settings(floorClearance: 0.02, cropHalfWidth: 0.5)),
] {
    let isolated = PersonIsolator.isolate(room, settings: settings)
    let repaired = MeshRepair.repair(isolated.triangles)
    let (lo, hi) = bounds(isolated.triangles)
    let handKept = hi.x > 0.23
    let passed = isolated.floorFound && isolated.personFound &&
        abs(lo.z - 0.02) < 0.005 && abs(hi.z - 1.7) < 0.005 &&
        lo.x > -0.21 && hi.x < 0.25 && lo.y > -0.21 && hi.y < 0.21 &&
        handKept && repaired.isValid
    if !passed { failures += 1 }
    print(
        name.padding(toLength: 16, withPad: " ", startingAt: 0),
        pad("\(isolated.floorFound)", 5),
        pad("\(isolated.personFound)", 7),
        pad(String(format: "%.3f", lo.z), 6),
        pad(String(format: "%.3f", hi.z), 7),
        pad(String(format: "%.3f", hi.x - lo.x), 7),
        pad("\(handKept)", 5),
        pad("\(repaired.isValid)", 6),
        passed ? " PASS" : " FAIL")
}

if failures > 0 {
    print("\(failures) mesh test(s) failed")
    exit(1)
}
print("All mesh tests passed")
