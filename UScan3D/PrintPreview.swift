import SceneKit
import UIKit
import simd

/// Renders the exact mesh that will be exported (after flat-base cut and
/// repair, placed and scaled to print size) so the preview matches the print.
enum PrintPreview {
    /// Flat-shaded, unindexed vertex data: three positions and normals per
    /// triangle, in millimeters, Z-up.
    struct Buffers: Sendable {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
    }

    /// The expensive part; safe to run off the main thread.
    static func buffers(for triangles: [Triangle], longestSideMM: Float) -> Buffers? {
        guard let placed = try? STLExporter.place(triangles, longestSideMM: longestSideMM) else { return nil }
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(placed.count * 3)
        normals.reserveCapacity(placed.count * 3)
        for triangle in placed {
            let cross = simd_cross(triangle.b - triangle.a, triangle.c - triangle.a)
            let length = simd_length(cross)
            let normal = length > 0 ? cross / length : SIMD3<Float>(0, 0, 1)
            positions.append(contentsOf: [triangle.a, triangle.b, triangle.c])
            normals.append(contentsOf: [normal, normal, normal])
        }
        return Buffers(positions: positions, normals: normals)
    }

    static func scene(from buffers: Buffers) -> SCNScene {
        let vertices = buffers.positions.map { SCNVector3($0.x, $0.y, $0.z) }
        let normals = buffers.normals.map { SCNVector3($0.x, $0.y, $0.z) }
        let indices = Array(0..<Int32(vertices.count))
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])

        // Single-sided on purpose: a face that's wound the wrong way shows
        // up as a hole here, just as it would confuse the slicer.
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGray2
        geometry.materials = [material]

        // The export is Z-up; SceneKit is Y-up.
        let model = SCNNode(geometry: geometry)
        model.eulerAngles.x = -Float.pi / 2

        let scene = SCNScene()
        scene.rootNode.addChildNode(model)
        return scene
    }
}
