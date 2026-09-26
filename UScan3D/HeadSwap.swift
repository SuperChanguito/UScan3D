import Foundation
import simd

/// Replaces a Full Body scan's head with the head from a separate Face / Bust
/// scan of the same person, for more facial detail. Both scans are Z-up,
/// meters (see STLExporter.loadTriangles), so no scaling is needed.
///
/// 1. Rough fit: the rigid transform that best maps three points the user
///    tapped on the bust (nose tip, left ear, right ear) onto the same
///    points on the body (Horn's quaternion method).
/// 2. Fine fit: ICP between surface samples of the two heads.
/// 3. The body is cut just under the chin and the bust a little lower, so
///    the two overlap at the neck. Each is sealed separately and exported
///    as overlapping solids, which the slicer merges — sewing two scans'
///    edges together exactly isn't reliable.
enum HeadSwap {

    struct Landmarks: Sendable {
        var nose: SIMD3<Float>
        var leftEar: SIMD3<Float>
        var rightEar: SIMD3<Float>

        var points: [SIMD3<Float>] { [nose, leftEar, rightEar] }
        var earMidpoint: SIMD3<Float> { (leftEar + rightEar) / 2 }
    }

    struct RigidTransform: Sendable {
        var rotation: simd_float3x3
        var translation: SIMD3<Float>

        static let identity = RigidTransform(rotation: matrix_identity_float3x3, translation: .zero)

        func apply(_ point: SIMD3<Float>) -> SIMD3<Float> {
            rotation * point + translation
        }

        func apply(_ triangle: Triangle) -> Triangle {
            Triangle(a: apply(triangle.a), b: apply(triangle.b), c: apply(triangle.c))
        }
    }

    struct Result: Sendable {
        /// Body then head, each sealed; they overlap at the neck.
        var triangles: [Triangle]
        var body: MeshRepair.Result
        var head: MeshRepair.Result
        /// Maps the bust into the body's coordinates.
        var transform: RigidTransform
        /// Root-mean-square gap between the fitted head surfaces (meters).
        var fitError: Float
    }

    /// Head surface used for fitting: everything this close to the midpoint
    /// between the ears. Keeps the shoulders out, since the head may be
    /// turned differently relative to them in the two scans.
    static let headRadius: Float = 0.14
    /// The body is cut this far below the ears (just under the chin)...
    static let bodyCutBelowEars: Float = 0.13
    /// ...and the bust this much lower again, so they overlap at the neck.
    static let neckOverlap: Float = 0.04

    static func combine(
        body: [Triangle], bodyLandmarks: Landmarks,
        bust: [Triangle], bustLandmarks: Landmarks
    ) -> Result? {
        guard let rough = rigidTransform(from: bustLandmarks.points, to: bodyLandmarks.points) else {
            return nil
        }

        let bodyPoints = surfacePoints(body, near: bodyLandmarks.earMidpoint, radius: headRadius)
        let bustPoints = surfacePoints(bust, near: bustLandmarks.earMidpoint, radius: headRadius)
        guard bodyPoints.count >= 3, bustPoints.count >= 3 else { return nil }
        let (transform, fitError) = refine(rough, source: bustPoints, target: bodyPoints)

        let cutZ = bodyLandmarks.earMidpoint.z - bodyCutBelowEars
        let bodyBelow = MeshCutter.clip(body, keepingAbove: SIMD3<Float>(0, 0, -1), offset: -cutZ)
        let placedBust = bust.map { transform.apply($0) }
        let headAbove = MeshCutter.clip(
            placedBust, keepingAbove: SIMD3<Float>(0, 0, 1), offset: cutZ - neckOverlap)
        guard !bodyBelow.isEmpty, !headAbove.isEmpty else { return nil }

        // Sealed separately: they overlap, and welding them together would
        // join unrelated vertices.
        let bodyResult = MeshRepair.repair(bodyBelow)
        let headResult = MeshRepair.repair(headAbove)
        return Result(
            triangles: bodyResult.triangles + headResult.triangles,
            body: bodyResult,
            head: headResult,
            transform: transform,
            fitError: fitError)
    }

    // MARK: - Rigid fit (Horn's method)

    /// The rotation + translation that best maps `source[i]` onto
    /// `target[i]` in the least-squares sense. nil if the points are
    /// degenerate (fewer than 3, or all in a line).
    static func rigidTransform(from source: [SIMD3<Float>], to target: [SIMD3<Float>]) -> RigidTransform? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        let n = Double(source.count)
        let s = source.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        let t = target.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        let sourceCentroid = s.reduce(.zero, +) / n
        let targetCentroid = t.reduce(.zero, +) / n

        // S[a][b] = Σ source'_a * target'_b over centered points.
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in s.indices {
            let a = s[i] - sourceCentroid
            let b = t[i] - targetCentroid
            for row in 0..<3 {
                for col in 0..<3 {
                    m[row][col] += a[row] * b[col]
                }
            }
        }
        // A spread of zero in two directions means the points are in a line.
        let spread = s.map { simd_length_squared($0 - sourceCentroid) }.reduce(0, +)
        guard spread > 1e-12 else { return nil }

        let (sxx, sxy, sxz) = (m[0][0], m[0][1], m[0][2])
        let (syx, syy, syz) = (m[1][0], m[1][1], m[1][2])
        let (szx, szy, szz) = (m[2][0], m[2][1], m[2][2])
        let nMatrix: [[Double]] = [
            [sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
        ]
        let q = largestEigenvector(nMatrix)
        let (w, x, y, z) = (q[0], q[1], q[2], q[3])
        let r: [[Double]] = [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
        ]
        let rotation = simd_float3x3(
            SIMD3<Float>(Float(r[0][0]), Float(r[1][0]), Float(r[2][0])),
            SIMD3<Float>(Float(r[0][1]), Float(r[1][1]), Float(r[2][1])),
            SIMD3<Float>(Float(r[0][2]), Float(r[1][2]), Float(r[2][2])))
        let rotatedCentroid = SIMD3<Double>(
            r[0][0] * sourceCentroid.x + r[0][1] * sourceCentroid.y + r[0][2] * sourceCentroid.z,
            r[1][0] * sourceCentroid.x + r[1][1] * sourceCentroid.y + r[1][2] * sourceCentroid.z,
            r[2][0] * sourceCentroid.x + r[2][1] * sourceCentroid.y + r[2][2] * sourceCentroid.z)
        let translation = targetCentroid - rotatedCentroid
        return RigidTransform(
            rotation: rotation,
            translation: SIMD3<Float>(Float(translation.x), Float(translation.y), Float(translation.z)))
    }

    /// Cyclic Jacobi eigen-decomposition of a symmetric 4×4 matrix; returns
    /// the (unit) eigenvector of the largest eigenvalue.
    private static func largestEigenvector(_ matrix: [[Double]]) -> [Double] {
        var a = matrix
        var v: [[Double]] = (0..<4).map { i in (0..<4).map { $0 == i ? 1 : 0 } }
        for _ in 0..<64 {
            var offDiagonal = 0.0
            for p in 0..<4 { for q in (p + 1)..<4 { offDiagonal += a[p][q] * a[p][q] } }
            if offDiagonal < 1e-22 { break }
            for p in 0..<3 {
                for q in (p + 1)..<4 where abs(a[p][q]) > 1e-300 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    for k in 0..<4 {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<4 {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<4 {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        let best = (0..<4).max { a[$0][$0] < a[$1][$1] } ?? 0
        return (0..<4).map { v[$0][best] }
    }

    // MARK: - ICP

    /// Iterative closest point: repeatedly pairs each (transformed) source
    /// point with its nearest target point and re-solves the rigid fit.
    /// The worst 20% of pairs are ignored each round, so parts one scan has
    /// and the other doesn't (hair, a collar) don't drag the fit. Returns
    /// the refined transform and its RMS gap.
    static func refine(
        _ initial: RigidTransform, source: [SIMD3<Float>], target: [SIMD3<Float>],
        iterations: Int = 40
    ) -> (RigidTransform, Float) {
        // Coarse search radius first (the tapped points can be a couple of
        // cm off), then tight.
        let coarse = PointGrid(target, cellSize: 0.03)
        let fine = PointGrid(target, cellSize: 0.01)

        var transform = initial
        var rms = Float.greatestFiniteMagnitude
        for iteration in 0..<iterations {
            let grid = iteration < iterations / 3 ? coarse : fine
            var pairs: [(source: SIMD3<Float>, target: SIMD3<Float>, distance: Float)] = []
            for point in source {
                if let (nearest, distance) = grid.nearest(to: transform.apply(point)) {
                    pairs.append((point, nearest, distance))
                }
            }
            guard pairs.count >= 3 else { break }
            pairs.sort { $0.distance < $1.distance }
            let kept = pairs.prefix(max(3, pairs.count * 8 / 10))
            guard let next = rigidTransform(from: kept.map(\.source), to: kept.map(\.target)) else { break }

            let newRMS = (kept.map { simd_length_squared(next.apply($0.source) - $0.target) }
                .reduce(0, +) / Float(kept.count)).squareRoot()
            transform = next
            let improvement = rms - newRMS
            rms = newRMS
            if iteration >= iterations / 3 && improvement >= 0 && improvement < 1e-6 { break }
        }
        return (transform, rms)
    }

    /// Uniform hash grid for nearest-neighbor lookups within one cell size.
    private struct PointGrid {
        let cellSize: Float
        var cells: [SIMD3<Int32>: [SIMD3<Float>]] = [:]

        init(_ points: [SIMD3<Float>], cellSize: Float) {
            self.cellSize = cellSize
            for point in points {
                cells[key(point), default: []].append(point)
            }
        }

        func key(_ point: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(
                Int32((point.x / cellSize).rounded(.down)),
                Int32((point.y / cellSize).rounded(.down)),
                Int32((point.z / cellSize).rounded(.down)))
        }

        /// Nearest point within `cellSize`, or nil.
        func nearest(to point: SIMD3<Float>) -> (SIMD3<Float>, Float)? {
            let center = key(point)
            var best: SIMD3<Float>?
            var bestDistance = cellSize * cellSize
            for dx in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dz in Int32(-1)...1 {
                        guard let bucket = cells[center &+ SIMD3(dx, dy, dz)] else { continue }
                        for candidate in bucket {
                            let distance = simd_length_squared(candidate - point)
                            if distance < bestDistance {
                                bestDistance = distance
                                best = candidate
                            }
                        }
                    }
                }
            }
            return best.map { ($0, bestDistance.squareRoot()) }
        }
    }

    // MARK: - Surface sampling

    /// Evenly spread points (about one per `spacing`² of area) on the
    /// surface within `radius` of `center`. Sampling the surface rather than
    /// using vertices makes the fit independent of how finely each scan was
    /// triangulated. Deterministic, and capped at `limit` points.
    static func surfacePoints(
        _ triangles: [Triangle], near center: SIMD3<Float>, radius: Float,
        spacing: Float = 0.004, limit: Int = 6000
    ) -> [SIMD3<Float>] {
        var random = SplitMix(seed: 0x5EED)
        var points: [SIMD3<Float>] = []
        let radiusSquared = radius * radius
        for triangle in triangles {
            let farthest = max(
                simd_length(triangle.a - triangle.b),
                simd_length(triangle.b - triangle.c),
                simd_length(triangle.c - triangle.a))
            // Skip triangles entirely outside the sphere.
            guard simd_length(triangle.a - center) <= radius + farthest else { continue }

            let area = simd_length(simd_cross(triangle.b - triangle.a, triangle.c - triangle.a)) / 2
            let expected = area / (spacing * spacing)
            var count = Int(expected)
            if random.nextUnit() < expected - Float(count) { count += 1 }
            for _ in 0..<count {
                var u = random.nextUnit()
                var v = random.nextUnit()
                if u + v > 1 { u = 1 - u; v = 1 - v }
                let point = triangle.a + (triangle.b - triangle.a) * u + (triangle.c - triangle.a) * v
                if simd_length_squared(point - center) <= radiusSquared {
                    points.append(point)
                }
            }
        }
        guard points.count > limit else { return points }
        let stride = Double(points.count) / Double(limit)
        return (0..<limit).map { points[Int(Double($0) * stride)] }
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1).
        mutating func nextUnit() -> Float {
            Float(next() >> 40) / Float(1 << 24)
        }
    }
}
