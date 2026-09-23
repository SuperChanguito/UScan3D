import Foundation
import simd

enum MeshCutter {

    /// Slices off the bottom `fraction` (0...1) of the mesh's height with a
    /// horizontal plane, discarding everything below it. Leaves the mesh
    /// open at the cut — pass the result through `MeshRepair.repair` to cap
    /// it with a flat base.
    static func cutFlatBase(_ triangles: [Triangle], fraction: Double) -> [Triangle] {
        guard fraction > 0, !triangles.isEmpty else { return triangles }

        var minZ = Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude
        for triangle in triangles {
            for vertex in [triangle.a, triangle.b, triangle.c] {
                minZ = min(minZ, vertex.z)
                maxZ = max(maxZ, vertex.z)
            }
        }
        guard maxZ > minZ else { return triangles }
        let planeZ = minZ + Float(fraction) * (maxZ - minZ)

        var kept: [Triangle] = []
        for triangle in triangles {
            kept.append(contentsOf: clip(triangle, above: planeZ))
        }
        return kept
    }

    /// Sutherland-Hodgman clip of one triangle against the half-space
    /// z >= planeZ, fan-triangulating the resulting (still convex) polygon.
    /// Vertex order is preserved, so winding/normals carry over unchanged.
    private static func clip(_ triangle: Triangle, above planeZ: Float) -> [Triangle] {
        let vertices = [triangle.a, triangle.b, triangle.c]
        var polygon: [SIMD3<Float>] = []
        for i in 0..<vertices.count {
            let current = vertices[i]
            let next = vertices[(i + 1) % vertices.count]
            let currentInside = current.z >= planeZ
            let nextInside = next.z >= planeZ
            if currentInside {
                polygon.append(current)
            }
            if currentInside != nextInside {
                let t = (planeZ - current.z) / (next.z - current.z)
                polygon.append(current + (next - current) * t)
            }
        }

        guard polygon.count >= 3 else { return [] }
        return (1..<(polygon.count - 1)).map {
            Triangle(a: polygon[0], b: polygon[$0], c: polygon[$0 + 1])
        }
    }
}
