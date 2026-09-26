import Foundation
import simd

/// Cuts a person out of an area-mode Full Body scan, which (having no
/// bounding box) also reconstructs the floor and whatever is around them.
/// Works on the Z-up, meters mesh from STLExporter.loadTriangles.
///
/// 1. Finds the floor: the lowest height with a large area of level faces.
/// 2. Slices everything below floor + clearance away, which also separates
///    the feet (and any walls) from the floor.
/// 3. Optionally crops to a square around the person.
/// 4. Keeps the connected piece standing closest to the middle of the floor
///    (the scan orbits the person, so the captured floor surrounds them),
///    plus small detached bits inside its outline, like a stray hand.
///
/// The result is open where it was cut; MeshRepair caps it.
enum PersonIsolator {

    struct Settings: Sendable, Equatable {
        /// How far above the detected floor to cut (meters). Floors come out
        /// bumpy, so cutting a little above them keeps floor scraps off the feet.
        var floorClearance: Float = 0.02
        /// Half the width of a square crop around the person (meters), or
        /// nil for no crop. For when something is touching them, like a chair.
        var cropHalfWidth: Float? = nil
    }

    struct Result: Sendable {
        var triangles: [Triangle]
        var floorFound: Bool
        /// False when nothing person-sized was found and the scan was
        /// returned unchanged.
        var personFound: Bool
    }

    /// A standing person is at least this tall (meters). Anything shorter is
    /// debris, a table top, or a fragment.
    private static let minimumPersonHeight: Float = 0.3
    private static let levelNormalZ: Float = 0.95
    private static let floorBinSize: Float = 0.01

    static func isolate(_ triangles: [Triangle], settings: Settings = Settings()) -> Result {
        guard !triangles.isEmpty else {
            return Result(triangles: triangles, floorFound: false, personFound: false)
        }

        let floor = findFloor(triangles)
        var working = triangles
        if let floor {
            working = MeshCutter.clip(
                working, keepingAbove: SIMD3<Float>(0, 0, 1), offset: floor.height + settings.floorClearance)
        }
        let center = floor?.center ?? areaCentroidXY(triangles)

        if let halfWidth = settings.cropHalfWidth {
            let planes: [(SIMD3<Float>, Float)] = [
                (SIMD3(1, 0, 0), center.x - halfWidth),
                (SIMD3(-1, 0, 0), -(center.x + halfWidth)),
                (SIMD3(0, 1, 0), center.y - halfWidth),
                (SIMD3(0, -1, 0), -(center.y + halfWidth)),
            ]
            for (normal, offset) in planes {
                working = MeshCutter.clip(working, keepingAbove: normal, offset: offset)
            }
        }

        let components = connectedComponents(working)
        guard let person = pickPerson(components, center: center) else {
            return Result(triangles: triangles, floorFound: floor != nil, personFound: false)
        }

        // Keep small detached pieces inside the person's outline (hands,
        // hair, fingers that reconstructed as separate islands).
        let margin: Float = 0.05
        var kept = person.triangles
        for component in components where component.id != person.id {
            let c = component.centroid
            let inside = c.x >= person.min.x - margin && c.x <= person.max.x + margin &&
                c.y >= person.min.y - margin && c.y <= person.max.y + margin &&
                c.z >= person.min.z - margin && c.z <= person.max.z + margin
            if inside && component.area < person.area * 0.2 {
                kept.append(contentsOf: component.triangles)
            }
        }
        return Result(triangles: kept, floorFound: floor != nil, personFound: true)
    }

    // MARK: - Floor

    struct Floor {
        var height: Float
        /// Area-weighted middle of the floor's level faces, in XY.
        var center: SIMD2<Float>
    }

    /// Bins the area of level faces by height (1 cm bins, smoothed over
    /// ±1 bin) and takes the lowest height carrying at least half the
    /// biggest bin's area — so a table top can't win over the floor.
    static func findFloor(_ triangles: [Triangle]) -> Floor? {
        var minZ = Float.greatestFiniteMagnitude
        for triangle in triangles {
            minZ = min(minZ, triangle.a.z, triangle.b.z, triangle.c.z)
        }

        var binArea: [Int: Float] = [:]
        var level: [(bin: Int, area: Float, centroid: SIMD3<Float>)] = []
        for triangle in triangles {
            let cross = simd_cross(triangle.b - triangle.a, triangle.c - triangle.a)
            let length = simd_length(cross)
            guard length > 0, abs(cross.z / length) > levelNormalZ else { continue }
            let area = length / 2
            let centroid = (triangle.a + triangle.b + triangle.c) / 3
            let bin = Int((centroid.z - minZ) / floorBinSize)
            binArea[bin, default: 0] += area
            level.append((bin, area, centroid))
        }
        guard !binArea.isEmpty else { return nil }

        func smoothed(_ bin: Int) -> Float {
            (binArea[bin - 1] ?? 0) + (binArea[bin] ?? 0) + (binArea[bin + 1] ?? 0)
        }
        let bins = binArea.keys.sorted()
        let peak = bins.map(smoothed).max() ?? 0
        // A floor ring around a person is square meters; a few cm² of level
        // faces is just the tops of shoulders and shoes.
        guard peak >= 0.05, let floorBin = bins.first(where: { smoothed($0) >= peak * 0.5 }) else {
            return nil
        }

        var weightedHeight: Float = 0
        var weightedXY = SIMD2<Float>(0, 0)
        var total: Float = 0
        for face in level where abs(face.bin - floorBin) <= 1 {
            weightedHeight += face.centroid.z * face.area
            weightedXY += SIMD2(face.centroid.x, face.centroid.y) * face.area
            total += face.area
        }
        guard total > 0 else { return nil }
        return Floor(height: weightedHeight / total, center: weightedXY / total)
    }

    private static func areaCentroidXY(_ triangles: [Triangle]) -> SIMD2<Float> {
        var weighted = SIMD2<Float>(0, 0)
        var total: Float = 0
        for triangle in triangles {
            let area = simd_length(simd_cross(triangle.b - triangle.a, triangle.c - triangle.a)) / 2
            let centroid = (triangle.a + triangle.b + triangle.c) / 3
            weighted += SIMD2(centroid.x, centroid.y) * area
            total += area
        }
        return total > 0 ? weighted / total : SIMD2(0, 0)
    }

    // MARK: - Components

    struct Component {
        var id: Int
        var triangles: [Triangle]
        var area: Float
        /// Area-weighted centroid.
        var centroid: SIMD3<Float>
        var min: SIMD3<Float>
        var max: SIMD3<Float>
        var height: Float { max.z - min.z }
    }

    /// Groups triangles that share (welded) vertices.
    static func connectedComponents(_ triangles: [Triangle]) -> [Component] {
        let mesh = MeshRepair.weld(triangles)
        var parent = Array(0..<mesh.vertices.count)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var node = x
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[rootA] = rootB }
        }
        for (a, b, c) in mesh.triangles {
            union(a, b)
            union(b, c)
        }

        var indexByRoot: [Int: Int] = [:]
        var components: [Component] = []
        var weightedCentroids: [SIMD3<Float>] = []
        for (a, b, c) in mesh.triangles {
            let root = find(a)
            let index: Int
            if let existing = indexByRoot[root] {
                index = existing
            } else {
                index = components.count
                indexByRoot[root] = index
                components.append(Component(
                    id: index, triangles: [], area: 0, centroid: .zero,
                    min: SIMD3(repeating: .greatestFiniteMagnitude),
                    max: SIMD3(repeating: -.greatestFiniteMagnitude)))
                weightedCentroids.append(.zero)
            }
            let triangle = Triangle(a: mesh.vertices[a], b: mesh.vertices[b], c: mesh.vertices[c])
            let area = simd_length(simd_cross(triangle.b - triangle.a, triangle.c - triangle.a)) / 2
            components[index].triangles.append(triangle)
            components[index].area += area
            weightedCentroids[index] += (triangle.a + triangle.b + triangle.c) / 3 * area
            for vertex in [triangle.a, triangle.b, triangle.c] {
                components[index].min = simd_min(components[index].min, vertex)
                components[index].max = simd_max(components[index].max, vertex)
            }
        }
        for index in components.indices where components[index].area > 0 {
            components[index].centroid = weightedCentroids[index] / components[index].area
        }
        return components
    }

    /// The person-tall piece nearest the middle of the floor. Tiny pieces
    /// (under 5% of the biggest tall piece) are ignored so debris right at
    /// the center can't win. Walls are usually bigger than the person, which
    /// is why this goes by position rather than size.
    private static func pickPerson(_ components: [Component], center: SIMD2<Float>) -> Component? {
        let tall = components.filter { $0.height >= minimumPersonHeight }
        guard let largestArea = tall.map(\.area).max() else { return nil }
        return tall
            .filter { $0.area >= largestArea * 0.05 }
            .min {
                simd_distance(SIMD2($0.centroid.x, $0.centroid.y), center) <
                    simd_distance(SIMD2($1.centroid.x, $1.centroid.y), center)
            }
    }
}
