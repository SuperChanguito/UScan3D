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
        return clip(triangles, keepingAbove: SIMD3<Float>(0, 0, 1), offset: planeZ)
    }

    /// Keeps the part of the mesh where dot(normal, p) >= offset, discarding
    /// the rest. Leaves the mesh open at the cut, like cutFlatBase.
    static func clip(_ triangles: [Triangle], keepingAbove normal: SIMD3<Float>, offset: Float) -> [Triangle] {
        var kept: [Triangle] = []
        for triangle in triangles {
            kept.append(contentsOf: clip(triangle, normal: normal, offset: offset))
        }
        return kept
    }

    /// Sutherland-Hodgman clip of one triangle against the half-space
    /// dot(normal, p) >= offset, fan-triangulating the resulting (still
    /// convex) polygon. Vertex order is preserved, so winding/normals carry
    /// over unchanged.
    private static func clip(_ triangle: Triangle, normal: SIMD3<Float>, offset: Float) -> [Triangle] {
        let vertices = [triangle.a, triangle.b, triangle.c]
        let distances = vertices.map { simd_dot(normal, $0) - offset }
        if distances.allSatisfy({ $0 >= 0 }) { return [triangle] }
        if distances.allSatisfy({ $0 < 0 }) { return [] }

        var polygon: [SIMD3<Float>] = []
        for i in 0..<vertices.count {
            let j = (i + 1) % vertices.count
            let current = vertices[i]
            let next = vertices[j]
            let currentInside = distances[i] >= 0
            let nextInside = distances[j] >= 0
            if currentInside {
                polygon.append(current)
            }
            if currentInside != nextInside {
                let t = distances[i] / (distances[i] - distances[j])
                polygon.append(current + (next - current) * t)
            }
        }

        guard polygon.count >= 3 else { return [] }
        return (1..<(polygon.count - 1)).map {
            Triangle(a: polygon[0], b: polygon[$0], c: polygon[$0 + 1])
        }
    }
}
