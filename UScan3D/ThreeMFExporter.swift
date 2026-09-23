import Foundation

enum ThreeMFExporter {

    /// Writes a minimal, spec-valid .3mf: an uncompressed OPC zip package
    /// containing the mesh as an indexed vertex/triangle list, in
    /// millimeters, already placed on the plate (see `STLExporter.place`).
    static func write3MF(_ triangles: [Triangle], to url: URL, longestSideMM: Float) throws {
        let placed = try STLExporter.place(triangles, longestSideMM: longestSideMM)
        let mesh = MeshRepair.weld(placed)
        let modelXML = build3DModelXML(mesh)

        var zip = ZipArchive()
        zip.addEntry(path: "[Content_Types].xml", data: Data(contentTypesXML.utf8))
        zip.addEntry(path: "_rels/.rels", data: Data(relsXML.utf8))
        zip.addEntry(path: "3D/3dmodel.model", data: Data(modelXML.utf8))
        try zip.write(to: url)
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
    """

    private static func build3DModelXML(_ mesh: IndexedMesh) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n"
        xml += "<resources><object id=\"1\" type=\"model\"><mesh><vertices>\n"
        xml.reserveCapacity(mesh.vertices.count * 48 + mesh.triangles.count * 36 + 512)

        for vertex in mesh.vertices {
            xml += "<vertex x=\"\(coordinate(vertex.x))\" y=\"\(coordinate(vertex.y))\" z=\"\(coordinate(vertex.z))\"/>\n"
        }
        xml += "</vertices><triangles>\n"
        for triangle in mesh.triangles {
            xml += "<triangle v1=\"\(triangle.0)\" v2=\"\(triangle.1)\" v3=\"\(triangle.2)\"/>\n"
        }
        xml += "</triangles></mesh></object></resources><build><item objectid=\"1\"/></build></model>\n"
        return xml
    }

    private static func coordinate(_ value: Float) -> String {
        String(format: "%.4f", value)
    }
}

/// A bare-bones ZIP writer: local file headers + central directory, all
/// entries stored uncompressed (method 0). Valid ZIP (and therefore valid
/// 3MF/OPC package) without needing a deflate implementation.
private struct ZipArchive {
    private struct Entry {
        let path: String
        let data: Data
        let crc32: UInt32
    }

    private var entries: [Entry] = []

    mutating func addEntry(path: String, data: Data) {
        entries.append(Entry(path: path, data: data, crc32: Self.crc32(of: data)))
    }

    func write(to url: URL) throws {
        var body = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            offsets.append(UInt32(body.count))
            let nameData = Data(entry.path.utf8)

            var header = Data()
            appendUInt32(0x0403_4b50, to: &header)
            appendUInt16(20, to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(0, to: &header)
            appendUInt32(entry.crc32, to: &header)
            appendUInt32(UInt32(entry.data.count), to: &header)
            appendUInt32(UInt32(entry.data.count), to: &header)
            appendUInt16(UInt16(nameData.count), to: &header)
            appendUInt16(0, to: &header)
            header.append(nameData)

            body.append(header)
            body.append(entry.data)
        }

        var centralDirectory = Data()
        for (index, entry) in entries.enumerated() {
            let nameData = Data(entry.path.utf8)
            var header = Data()
            appendUInt32(0x0201_4b50, to: &header)
            appendUInt16(20, to: &header)
            appendUInt16(20, to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(0, to: &header)
            appendUInt32(entry.crc32, to: &header)
            appendUInt32(UInt32(entry.data.count), to: &header)
            appendUInt32(UInt32(entry.data.count), to: &header)
            appendUInt16(UInt16(nameData.count), to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(0, to: &header)
            appendUInt32(0, to: &header)
            appendUInt32(offsets[index], to: &header)
            header.append(nameData)
            centralDirectory.append(header)
        }

        var end = Data()
        appendUInt32(0x0605_4b50, to: &end)
        appendUInt16(0, to: &end)
        appendUInt16(0, to: &end)
        appendUInt16(UInt16(entries.count), to: &end)
        appendUInt16(UInt16(entries.count), to: &end)
        appendUInt32(UInt32(centralDirectory.count), to: &end)
        appendUInt32(UInt32(body.count), to: &end)
        appendUInt16(0, to: &end)

        var output = body
        output.append(centralDirectory)
        output.append(end)
        try output.write(to: url, options: .atomic)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
