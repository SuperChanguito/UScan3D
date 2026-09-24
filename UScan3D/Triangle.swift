import simd

/// One triangle of a mesh, as a plain triangle soup. Kept in its own file so
/// the mesh code (MeshRepair, MeshCutter) builds standalone in the CI tests.
struct Triangle: Sendable {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var c: SIMD3<Float>
}
