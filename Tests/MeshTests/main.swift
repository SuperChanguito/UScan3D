// Mesh repair regression tests. A plain executable (no XCTest) so CI can
// build it with swiftc alongside the app's mesh code:
//
//   swiftc UScan3D/Triangle.swift UScan3D/MeshRepair.swift UScan3D/MeshCutter.swift \
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

if failures > 0 {
    print("\(failures) mesh test(s) failed")
    exit(1)
}
print("All mesh tests passed")
