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
    }

    /// Welds coincident vertices, finds boundary loops (holes), caps each
    /// with a triangle fan, and returns the repaired triangle soup.
    static func repair(_ triangles: [Triangle]) -> Result {
        guard !triangles.isEmpty else {
            return Result(triangles: triangles, wasWatertight: true, holesFilled: 0)
        }

        var mesh = weld(triangles)
        let loops = boundaryLoops(of: mesh)
        guard !loops.isEmpty else {
            return Result(triangles: triangles, wasWatertight: true, holesFilled: 0)
        }

        for loop in loops {
            fill(loop, in: &mesh)
        }

        let repaired = mesh.triangles.map {
            Triangle(a: mesh.vertices[$0.0], b: mesh.vertices[$0.1], c: mesh.vertices[$0.2])
        }
        return Result(triangles: repaired, wasWatertight: false, holesFilled: loops.count)
    }

    /// Merges vertices within a small tolerance (0.01mm at scan scale) so
    /// shared edges between submeshes are recognized as the same edge.
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
            indexed.append((index(for: triangle.a), index(for: triangle.b), index(for: triangle.c)))
        }
        return IndexedMesh(vertices: vertices, triangles: indexed)
    }

    /// Boundary edges are directed edges with no matching reverse edge
    /// elsewhere in the mesh. Chains them tip-to-tail into closed loops.
    private static func boundaryLoops(of mesh: IndexedMesh) -> [[Int]] {
        var directedEdges: Set<SIMD2<Int32>> = []
        for (a, b, c) in mesh.triangles {
            directedEdges.insert(SIMD2(Int32(a), Int32(b)))
            directedEdges.insert(SIMD2(Int32(b), Int32(c)))
            directedEdges.insert(SIMD2(Int32(c), Int32(a)))
        }

        var next: [Int: Int] = [:]
        for edge in directedEdges where !directedEdges.contains(SIMD2(edge.y, edge.x)) {
            next[Int(edge.x)] = Int(edge.y)
        }

        var loops: [[Int]] = []
        var visited: Set<Int> = []
        for start in next.keys where !visited.contains(start) {
            var loop: [Int] = []
            var current = start
            while !visited.contains(current), let following = next[current] {
                visited.insert(current)
                loop.append(current)
                current = following
                if current == start { break }
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    /// Caps a hole with a triangle fan from its centroid. Each existing
    /// boundary edge (v_i, v_i+1) must appear reversed in the new triangle
    /// per the shared-edge winding rule, so the cap is wound
    /// (centroid, v_i+1, v_i).
    private static func fill(_ loop: [Int], in mesh: inout IndexedMesh) {
        let positions = loop.map { mesh.vertices[$0] }
        let centroid = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
        let centroidIndex = mesh.vertices.count
        mesh.vertices.append(centroid)

        for i in 0..<loop.count {
            let next = (i + 1) % loop.count
            mesh.triangles.append((centroidIndex, loop[next], loop[i]))
        }
    }
}
