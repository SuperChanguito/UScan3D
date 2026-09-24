import Foundation
import ModelIO
import simd

enum STLExportError: LocalizedError {
    case noGeometry

    var errorDescription: String? {
        switch self {
        case .noGeometry:
            return "The scan doesn't contain any usable geometry."
        }
    }
}

enum STLExporter {

    /// Reads every mesh in the USDZ, bakes node transforms, and converts from
    /// USD's Y-up axes (meters) to the printer's Z-up orientation.
    static func loadTriangles(from modelURL: URL) throws -> [Triangle] {
        let asset = MDLAsset(url: modelURL)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }

        var triangles: [Triangle] = []
        for mesh in meshes {
            let transform = worldTransform(of: mesh)
            guard let positions = mesh.vertexAttributeData(
                forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
                continue
            }

            func point(_ index: UInt32) -> SIMD3<Float> {
                let raw = positions.dataStart.advanced(by: Int(index) * positions.stride)
                let p = raw.assumingMemoryBound(to: Float.self)
                let world = transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                return SIMD3(world.x, -world.z, world.y) // Y-up -> Z-up
            }

            let submeshes = mesh.submeshes?.compactMap { $0 as? MDLSubmesh } ?? []
            for submesh in submeshes where submesh.geometryType == .triangles {
                let indexBuffer = submesh.indexBuffer(asIndexType: .uInt32)
                let map = indexBuffer.map()
                withExtendedLifetime((positions, map)) {
                    let indices = map.bytes.assumingMemoryBound(to: UInt32.self)
                    var i = 0
                    while i + 2 < submesh.indexCount {
                        triangles.append(Triangle(
                            a: point(indices[i]),
                            b: point(indices[i + 1]),
                            c: point(indices[i + 2])))
                        i += 3
                    }
                }
            }
        }

        guard !triangles.isEmpty else { throw STLExportError.noGeometry }
        return triangles
    }

    /// Real-world dimensions of the scan in millimeters (scan units are meters).
    static func sizeMM(of triangles: [Triangle]) -> SIMD3<Float> {
        let (minPoint, maxPoint) = bounds(of: triangles)
        return (maxPoint - minPoint) * 1000
    }

    /// Scales the mesh so its longest side is `longestSideMM`, centers it on
    /// X/Y, and rests it on Z = 0 so it lands on the build plate in the
    /// slicer. Shared by every export format.
    static func place(_ triangles: [Triangle], longestSideMM: Float) throws -> [Triangle] {
        guard !triangles.isEmpty else { throw STLExportError.noGeometry }

        let (minPoint, maxPoint) = bounds(of: triangles)
        let extent = maxPoint - minPoint
        let longest = max(extent.x, max(extent.y, extent.z))
        let scale = longest > 0 ? longestSideMM / longest : 1
        let anchor = SIMD3<Float>((minPoint.x + maxPoint.x) / 2, (minPoint.y + maxPoint.y) / 2, minPoint.z)

        func placeVertex(_ vertex: SIMD3<Float>) -> SIMD3<Float> {
            (vertex - anchor) * scale
        }

        return triangles.map {
            Triangle(a: placeVertex($0.a), b: placeVertex($0.b), c: placeVertex($0.c))
        }
    }

    /// Binary STL of an already-placed mesh (see `place(_:longestSideMM:)`).
    static func writeBinarySTL(_ triangles: [Triangle], to url: URL, longestSideMM: Float) throws {
        let placedTriangles = try place(triangles, longestSideMM: longestSideMM)

        var data = Data()
        data.reserveCapacity(84 + placedTriangles.count * 50)

        var header = Data("U-Scan3D binary STL".utf8)
        header.append(Data(count: 80 - header.count))
        data.append(header)
        appendUInt32(UInt32(placedTriangles.count), to: &data)

        for triangle in placedTriangles {
            let a = triangle.a
            let b = triangle.b
            let c = triangle.c
            var normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            normal = length > 0 ? normal / length : SIMD3<Float>(0, 0, 0)

            for vector in [normal, a, b, c] {
                appendFloat(vector.x, to: &data)
                appendFloat(vector.y, to: &data)
                appendFloat(vector.z, to: &data)
            }
            data.append(contentsOf: [0, 0]) // attribute byte count
        }

        try data.write(to: url, options: .atomic)
    }

    private static func bounds(of triangles: [Triangle]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var minPoint = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for triangle in triangles {
            for vertex in [triangle.a, triangle.b, triangle.c] {
                minPoint = simd_min(minPoint, vertex)
                maxPoint = simd_max(maxPoint, vertex)
            }
        }
        return (minPoint, maxPoint)
    }

    private static func worldTransform(of object: MDLObject) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        var node: MDLObject? = object
        while let current = node {
            if let transform = current.transform {
                matrix = transform.matrix * matrix
            }
            node = current.parent
        }
        return matrix
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
