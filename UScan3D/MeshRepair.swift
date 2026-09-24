import Foundation
import simd

/// A mesh with shared vertices, needed to find boundary edges and holes
/// (and to write a compact indexed format like 3MF). Photogrammetry output
/// can span several submeshes with duplicated vertices at their shared
/// boundaries, so positions are welded first.
struct IndexedMesh {
    var vertices: [SIMD3<Float>]
    var triangles: [(Int, Int, Int)]
}

enum MeshRepair {
    struct Result: Sendable {
        var triangles: [Triangle]
        var wasWatertight: Bool
        var holesFilled: Int
        /// The cap triangles added by the repair are the last
        /// `capTriangleCount` entries of `triangles`.
        var capTriangleCount: Int
        /// Directed edges that aren't matched by exactly one opposite edge.
        var badEdgeCount: Int
        /// Planar cap triangles whose normal points into the model.
        var upsideDownCapFaces: Int
        /// Holes that needed a fallback (centroid fan, unclosed boundary,
        /// inconsistent nesting) and may not be capped cleanly.
        var warningCount: Int

        /// Every edge is shared by exactly two triangles with opposite
        /// directions, and no planar cap faces the wrong way.
        var isValid: Bool { badEdgeCount == 0 && upsideDownCapFaces == 0 }
    }

    /// Welds coincident vertices, finds boundary loops (holes), and caps
    /// them. Coplanar loops (like a flat-base cut) are capped together, so a
    /// ring-shaped cross-section gets an annulus rather than two overlapping
    /// disks; each cap is ear-clipped rather than fanned, so non-convex
    /// outlines are covered exactly once.
    static func repair(_ triangles: [Triangle]) -> Result {
        guard !triangles.isEmpty else {
            return Result(
                triangles: triangles, wasWatertight: true, holesFilled: 0, capTriangleCount: 0,
                badEdgeCount: 0, upsideDownCapFaces: 0, warningCount: 0)
        }

        var mesh = weld(triangles)
        let (loops, openEdgeCount) = boundaryLoops(of: mesh)
        var warningCount = openEdgeCount > 0 ? 1 : 0

        let infos = loops.map { loopInfo($0, in: mesh) }
        var caps: [CapTriangle] = []
        for group in coplanarGroups(infos) {
            capGroup(group, infos: infos, mesh: &mesh, caps: &caps, warningCount: &warningCount)
        }
        mesh.triangles.append(contentsOf: caps.map { $0.indices })

        let (badEdgeCount, upsideDownCapFaces) = validate(mesh, caps: caps)
        let repaired = mesh.triangles.map {
            Triangle(a: mesh.vertices[$0.0], b: mesh.vertices[$0.1], c: mesh.vertices[$0.2])
        }
        return Result(
            triangles: repaired,
            wasWatertight: loops.isEmpty && openEdgeCount == 0,
            holesFilled: loops.count,
            capTriangleCount: caps.count,
            badEdgeCount: badEdgeCount,
            upsideDownCapFaces: upsideDownCapFaces,
            warningCount: warningCount)
    }

    /// Merges vertices within a small tolerance (0.01mm at scan scale) so
    /// shared edges between submeshes are recognized as the same edge.
    /// Triangles that collapse to a line or point are dropped.
    static func weld(_ triangles: [Triangle], epsilon: Float = 1e-5) -> IndexedMesh {
        var vertices: [SIMD3<Float>] = []
        var lookup: [SIMD3<Int32>: Int] = [:]

        func index(for point: SIMD3<Float>) -> Int {
            let key = SIMD3<Int32>(
                Int32((point.x / epsilon).rounded()),
                Int32((point.y / epsilon).rounded()),
                Int32((point.z / epsilon).rounded()))
            if let existing = lookup[key] { return existing }
            let newIndex = vertices.count
            vertices.append(point)
            lookup[key] = newIndex
            return newIndex
        }

        var indexed: [(Int, Int, Int)] = []
        indexed.reserveCapacity(triangles.count)
        for triangle in triangles {
            let a = index(for: triangle.a)
            let b = index(for: triangle.b)
            let c = index(for: triangle.c)
            guard a != b, b != c, c != a else { continue }
            indexed.append((a, b, c))
        }
        return IndexedMesh(vertices: vertices, triangles: indexed)
    }

    // MARK: - Boundary loops

    private static func directedEdgeCounts(_ triangles: [(Int, Int, Int)]) -> [SIMD2<Int32>: Int] {
        var counts: [SIMD2<Int32>: Int] = [:]
        counts.reserveCapacity(triangles.count * 3)
        for (a, b, c) in triangles {
            counts[SIMD2(Int32(a), Int32(b)), default: 0] += 1
            counts[SIMD2(Int32(b), Int32(c)), default: 0] += 1
            counts[SIMD2(Int32(c), Int32(a)), default: 0] += 1
        }
        return counts
    }

    /// Boundary edges are directed edges not cancelled by a reverse edge.
    /// Every one is kept (a vertex can have several outgoing boundary edges
    /// where holes touch) and consumed exactly once while walking them
    /// tip-to-tail; whenever the walk revisits a vertex, the closed sub-loop
    /// is split off. Chains that can't close are counted, never capped.
    private static func boundaryLoops(of mesh: IndexedMesh) -> (loops: [[Int]], openEdgeCount: Int) {
        let counts = directedEdgeCounts(mesh.triangles)
        var outgoing: [Int: [Int]] = [:]
        for (edge, count) in counts {
            let unmatched = count - (counts[SIMD2(edge.y, edge.x)] ?? 0)
            if unmatched > 0 {
                outgoing[Int(edge.x), default: []].append(
                    contentsOf: repeatElement(Int(edge.y), count: unmatched))
            }
        }
        // Sorted descending so popLast() deterministically takes the smallest.
        outgoing = outgoing.mapValues { $0.sorted(by: >) }

        var loops: [[Int]] = []
        var openEdgeCount = 0
        for start in outgoing.keys.sorted() {
            while let first = outgoing[start]?.popLast() {
                var path = [start]
                var position: [Int: Int] = [start: 0]
                var next: Int? = first
                while let vertex = next {
                    if let i = position[vertex] {
                        let cycle = Array(path[i...])
                        if cycle.count >= 3 {
                            loops.append(cycle)
                        } else {
                            openEdgeCount += cycle.count
                        }
                        for dropped in path[(i + 1)...] {
                            position[dropped] = nil
                        }
                        path.removeSubrange((i + 1)...)
                    } else {
                        position[vertex] = path.count
                        path.append(vertex)
                    }
                    next = outgoing[vertex]?.popLast()
                }
                openEdgeCount += path.count - 1
            }
        }
        return (loops, openEdgeCount)
    }

    // MARK: - Capping

    private struct LoopInfo {
        var loop: [Int]
        /// Unit normal the cap must face (outward), from Newell's method.
        var capNormal: SIMD3<Double>
        var area: Double
        var centroid: SIMD3<Double>
        var tolerance: Double
        var isPlanar: Bool
    }

    private struct CapTriangle {
        var indices: (Int, Int, Int)
        /// Set for planar caps; used to check the triangle isn't upside down.
        var expectedNormal: SIMD3<Double>?
    }

    private struct PolygonVertex {
        var id: Int
        var point: SIMD2<Double>
    }

    private static func double3(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
    }

    private static func loopInfo(_ loop: [Int], in mesh: IndexedMesh) -> LoopInfo {
        let points = loop.map { double3(mesh.vertices[$0]) }
        var newell = SIMD3<Double>(0, 0, 0)
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            newell += SIMD3<Double>(
                (a.y - b.y) * (a.z + b.z),
                (a.z - b.z) * (a.x + b.x),
                (a.x - b.x) * (a.y + b.y))
        }
        let length = simd_length(newell)
        let centroid = points.reduce(SIMD3<Double>(0, 0, 0), +) / Double(points.count)
        let radius = points.map { simd_length($0 - centroid) }.max() ?? 0
        let unit = length > 0 ? newell / length : SIMD3<Double>(0, 0, 1)
        let tolerance = max(1e-6, 1e-3 * radius)
        let isPlanar = length > 0 && points.allSatisfy { abs(simd_dot(unit, $0 - centroid)) <= tolerance }
        // The loop runs along the boundary edges; the cap uses them reversed,
        // so it faces the opposite way to the loop's own Newell normal.
        return LoopInfo(
            loop: loop, capNormal: -unit, area: length / 2, centroid: centroid,
            tolerance: tolerance, isPlanar: isPlanar)
    }

    /// Groups planar loops lying in the same plane (either facing), largest
    /// first, so outlines and the holes inside them are capped together.
    private static func coplanarGroups(_ infos: [LoopInfo]) -> [[Int]] {
        let order = infos.indices.sorted { infos[$0].area > infos[$1].area }
        var assigned = [Bool](repeating: false, count: infos.count)
        var groups: [[Int]] = []
        for i in order where !assigned[i] {
            assigned[i] = true
            var group = [i]
            if infos[i].isPlanar {
                for j in order where !assigned[j] && infos[j].isPlanar {
                    let a = infos[i]
                    let b = infos[j]
                    if abs(simd_dot(a.capNormal, b.capNormal)) > 0.999,
                       abs(simd_dot(a.capNormal, b.centroid - a.centroid)) <= max(a.tolerance, b.tolerance) {
                        assigned[j] = true
                        group.append(j)
                    }
                }
            }
            groups.append(group)
        }
        return groups
    }

    /// Caps one group of coplanar loops (or a single non-planar loop):
    /// projects them to 2D, nests them by containment (even depth = outline,
    /// odd depth = hole in it), bridges holes into their outline and
    /// ear-clips. Each cap polygon is its loop reversed, which is exactly the
    /// shared-edge winding rule: boundary edge (v_i, v_i+1) appears in the
    /// cap as (v_i+1, v_i), so cap normals point outward.
    private static func capGroup(
        _ group: [Int],
        infos: [LoopInfo],
        mesh: inout IndexedMesh,
        caps: inout [CapTriangle],
        warningCount: inout Int
    ) {
        let reference = infos[group[0]]
        let normal = reference.capNormal
        let (u, v) = planeBasis(normal: normal)
        func expectedNormal(_ sign: Double) -> SIMD3<Double>? {
            reference.isPlanar ? normal * sign : nil
        }

        let polygons: [[PolygonVertex]] = group.map { loopIndex in
            infos[loopIndex].loop.reversed().map { id in
                let p = double3(mesh.vertices[id])
                return PolygonVertex(id: id, point: SIMD2<Double>(simd_dot(p, u), simd_dot(p, v)))
            }
        }
        let areas = polygons.map(signedArea)
        let depths = polygons.indices.map { b in
            polygons.indices.filter { a in
                a != b && abs(areas[a]) > abs(areas[b]) && isPoint(polygons[b][0].point, inside: polygons[a])
            }.count
        }

        // Outlines must wind counter-clockwise in the plane and holes
        // clockwise; a loop that disagrees with its nesting role is capped
        // on its own.
        var outlines: [(polygon: Int, holes: [Int])] = []
        var standalone: [Int] = []
        for k in polygons.indices where depths[k] % 2 == 0 {
            if areas[k] > 0 {
                outlines.append((polygon: k, holes: []))
            } else {
                standalone.append(k)
            }
        }
        for k in polygons.indices where depths[k] % 2 == 1 {
            var parent: Int?
            for (o, outline) in outlines.enumerated()
            where depths[outline.polygon] == depths[k] - 1 && isPoint(polygons[k][0].point, inside: polygons[outline.polygon]) {
                if let current = parent, abs(areas[outlines[current].polygon]) <= abs(areas[outline.polygon]) {
                    continue
                }
                parent = o
            }
            if let parent, areas[k] < 0 {
                outlines[parent].holes.append(k)
            } else {
                standalone.append(k)
            }
        }

        let scale = group.map { infos[$0].area.squareRoot() }.max() ?? 0
        let epsilon = max(1e-9, scale * 1e-7)

        for outline in outlines {
            let merged: [PolygonVertex]? = outline.holes.isEmpty
                ? polygons[outline.polygon]
                : bridgeHoles(
                    outer: polygons[outline.polygon],
                    holes: outline.holes.map { polygons[$0] },
                    epsilon: epsilon)
            if let merged, let triangles = earClip(merged, epsilon: epsilon) {
                caps += triangles.map { CapTriangle(indices: $0, expectedNormal: expectedNormal(1)) }
            } else {
                warningCount += 1
                for k in [outline.polygon] + outline.holes {
                    appendFan(infos[group[k]].loop, mesh: &mesh, caps: &caps)
                }
            }
        }

        for k in standalone {
            let sign: Double = areas[k] >= 0 ? 1 : -1
            let oriented = polygons[k].map {
                PolygonVertex(id: $0.id, point: SIMD2<Double>($0.point.x * sign, $0.point.y))
            }
            if group.count > 1 { warningCount += 1 }
            if let triangles = earClip(oriented, epsilon: epsilon) {
                caps += triangles.map { CapTriangle(indices: $0, expectedNormal: expectedNormal(sign)) }
            } else {
                warningCount += 1
                appendFan(infos[group[k]].loop, mesh: &mesh, caps: &caps)
            }
        }
    }

    /// Fallback: caps a hole with a triangle fan from its centroid, wound
    /// (centroid, v_i+1, v_i). Only correct for convex-ish holes.
    private static func appendFan(_ loop: [Int], mesh: inout IndexedMesh, caps: inout [CapTriangle]) {
        let positions = loop.map { mesh.vertices[$0] }
        let centroid = positions.reduce(SIMD3<Float>(0, 0, 0), +) / Float(positions.count)
        let centroidIndex = mesh.vertices.count
        mesh.vertices.append(centroid)
        for i in 0..<loop.count {
            caps.append(CapTriangle(
                indices: (centroidIndex, loop[(i + 1) % loop.count], loop[i]),
                expectedNormal: nil))
        }
    }

    // MARK: - 2D polygon helpers

    /// Orthonormal (u, v) spanning the plane, with u × v = normal, so a
    /// polygon wound counter-clockwise in (u, v) faces `normal`.
    private static func planeBasis(normal: SIMD3<Double>) -> (u: SIMD3<Double>, v: SIMD3<Double>) {
        let helper = abs(normal.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u = simd_normalize(helper - normal * simd_dot(helper, normal))
        return (u, simd_cross(normal, u))
    }

    private static func cross2(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    private static func signedArea(_ polygon: [PolygonVertex]) -> Double {
        var sum = 0.0
        for i in polygon.indices {
            let a = polygon[i].point
            let b = polygon[(i + 1) % polygon.count].point
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Even-odd point-in-polygon test.
    private static func isPoint(_ q: SIMD2<Double>, inside polygon: [PolygonVertex]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i].point
            let pj = polygon[j].point
            if (pi.y > q.y) != (pj.y > q.y),
               q.x < (pj.x - pi.x) * (q.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func coincident(_ a: SIMD2<Double>, _ b: SIMD2<Double>, epsilon: Double) -> Bool {
        abs(a.x - b.x) <= epsilon && abs(a.y - b.y) <= epsilon
    }

    /// Joins clockwise holes into a counter-clockwise outline with a
    /// zero-width bridge each (Eberly, "Triangulation by Ear Clipping"):
    /// from the hole's rightmost vertex, cast a ray in +x to the nearest
    /// outline edge and connect to a vertex visible from there.
    private static func bridgeHoles(
        outer: [PolygonVertex], holes: [[PolygonVertex]], epsilon: Double
    ) -> [PolygonVertex]? {
        var polygon = outer
        let ordered = holes.map { hole -> (hole: [PolygonVertex], rightmost: Int) in
            let rightmost = hole.indices.max { hole[$0].point.x < hole[$1].point.x } ?? 0
            return (hole, rightmost)
        }.sorted { $0.hole[$0.rightmost].point.x > $1.hole[$1.rightmost].point.x }

        for (hole, rightmost) in ordered {
            let m = hole[rightmost].point
            var bestX = Double.infinity
            var edgeIndex: Int?
            for i in polygon.indices {
                let a = polygon[i].point
                let b = polygon[(i + 1) % polygon.count].point
                // Only upward edges: the outline's interior is on their left,
                // i.e. facing the hole.
                guard a.y < b.y, a.y <= m.y, m.y <= b.y else { continue }
                let x = a.x + (m.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if x >= m.x - epsilon && x < bestX {
                    bestX = x
                    edgeIndex = i
                }
            }
            guard let edgeIndex else { return nil }

            let ia = edgeIndex
            let ib = (edgeIndex + 1) % polygon.count
            let a = polygon[ia].point
            let b = polygon[ib].point
            let hit = SIMD2<Double>(bestX, m.y)
            var bridgeIndex: Int
            if coincident(a, hit, epsilon: epsilon) {
                bridgeIndex = ia
            } else if coincident(b, hit, epsilon: epsilon) {
                bridgeIndex = ib
            } else {
                bridgeIndex = a.x > b.x ? ia : ib
                let p = polygon[bridgeIndex].point
                let corners = cross2(m, hit, p) > 0 ? (m, hit, p) : (m, p, hit)
                // A reflex vertex inside triangle (m, hit, p) would block the
                // bridge; use the one closest in angle to the ray instead.
                var bestDistance = simd_length(p - m)
                var bestCosine = (p.x - m.x) / bestDistance
                for i in polygon.indices where i != bridgeIndex {
                    let q = polygon[i].point
                    let previous = polygon[(i + polygon.count - 1) % polygon.count].point
                    let next = polygon[(i + 1) % polygon.count].point
                    guard cross2(previous, q, next) <= 0 else { continue }
                    guard cross2(corners.0, corners.1, q) >= 0,
                          cross2(corners.1, corners.2, q) >= 0,
                          cross2(corners.2, corners.0, q) >= 0 else { continue }
                    let distance = simd_length(q - m)
                    guard distance > epsilon else { continue }
                    let cosine = (q.x - m.x) / distance
                    if cosine > bestCosine + 1e-12 ||
                        (abs(cosine - bestCosine) <= 1e-12 && distance < bestDistance) {
                        bestCosine = cosine
                        bestDistance = distance
                        bridgeIndex = i
                    }
                }
            }

            let holeSequence = Array(hole[rightmost...]) + Array(hole[..<rightmost]) + [hole[rightmost]]
            polygon = Array(polygon[...bridgeIndex]) + holeSequence + [polygon[bridgeIndex]] +
                Array(polygon[(bridgeIndex + 1)...])
        }
        return polygon
    }

    /// Ear-clips a counter-clockwise polygon (holes already bridged in).
    /// Collinear vertices are kept: they're boundary vertices the cap must
    /// share edges with. If only degenerate corners remain, they're removed
    /// with zero-area triangles so the boundary stays closed. Returns nil if
    /// no ear can be found (self-intersecting input).
    private static func earClip(_ polygon: [PolygonVertex], epsilon: Double) -> [(Int, Int, Int)]? {
        guard polygon.count >= 3 else { return nil }
        let areaEpsilon = epsilon * epsilon
        var ring = Array(polygon.indices)
        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(polygon.count)
        var start = 0
        var iterations = 0

        while ring.count > 3 {
            iterations += 1
            if iterations > 10 * polygon.count + 100 { return nil }
            let m = ring.count
            var clipIndex: Int?
            for step in 0..<m {
                let j = (start + step) % m
                let ia = ring[(j + m - 1) % m]
                let ib = ring[j]
                let ic = ring[(j + 1) % m]
                let a = polygon[ia].point
                let b = polygon[ib].point
                let c = polygon[ic].point
                guard cross2(a, b, c) > areaEpsilon else { continue }
                var blocked = false
                for x in ring where x != ia && x != ib && x != ic {
                    let q = polygon[x].point
                    if coincident(q, a, epsilon: epsilon) ||
                        coincident(q, b, epsilon: epsilon) ||
                        coincident(q, c, epsilon: epsilon) {
                        continue
                    }
                    if cross2(a, b, q) >= -areaEpsilon,
                       cross2(b, c, q) >= -areaEpsilon,
                       cross2(c, a, q) >= -areaEpsilon {
                        blocked = true
                        break
                    }
                }
                if !blocked {
                    clipIndex = j
                    break
                }
            }
            if clipIndex == nil {
                clipIndex = (0..<m).first { j in
                    abs(cross2(
                        polygon[ring[(j + m - 1) % m]].point,
                        polygon[ring[j]].point,
                        polygon[ring[(j + 1) % m]].point)) <= areaEpsilon
                }
            }
            guard let j = clipIndex else { return nil }
            triangles.append((
                polygon[ring[(j + m - 1) % m]].id,
                polygon[ring[j]].id,
                polygon[ring[(j + 1) % m]].id))
            ring.remove(at: j)
            start = j % ring.count
        }
        triangles.append((polygon[ring[0]].id, polygon[ring[1]].id, polygon[ring[2]].id))
        return triangles
    }

    // MARK: - Validation

    /// Checks the repaired mesh: every directed edge must be matched by
    /// exactly one opposite edge (closed and consistently wound), and every
    /// non-degenerate planar cap triangle must face its expected normal.
    private static func validate(_ mesh: IndexedMesh, caps: [CapTriangle]) -> (badEdges: Int, upsideDown: Int) {
        let counts = directedEdgeCounts(mesh.triangles)
        var badEdges = 0
        for (edge, count) in counts where count != 1 || counts[SIMD2(edge.y, edge.x)] != 1 {
            badEdges += 1
        }

        var upsideDown = 0
        for cap in caps {
            guard let expected = cap.expectedNormal else { continue }
            let a = double3(mesh.vertices[cap.indices.0])
            let b = double3(mesh.vertices[cap.indices.1])
            let c = double3(mesh.vertices[cap.indices.2])
            let normal = simd_cross(b - a, c - a)
            // Skip slivers (collinear boundary points), whose direction is noise.
            guard simd_length(normal) > 1e-6 * simd_length(b - a) * simd_length(c - a) else { continue }
            if simd_dot(normal, expected) < 0 {
                upsideDown += 1
            }
        }
        return (badEdges, upsideDown)
    }
}
