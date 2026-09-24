import Foundation
import Network

struct PrinterSettings: Codable, Equatable {
    var host: String
    var accessCode: String

    private static let userDefaultsKey = "com.mrgrisafe.UScan3D.printerSettings"

    static func load() -> PrinterSettings? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(PrinterSettings.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }
}

enum PrinterUploadError: LocalizedError {
    case missingSettings
    case connectionFailed(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingSettings:
            return "Set up the printer's IP address and access code first."
        case .connectionFailed(let message):
            return "Couldn't connect to the printer: \(message)"
        case .unexpectedResponse(let message):
            return "Unexpected response from the printer: \(message)"
        }
    }
}

/// Uploads a print file to a Bambu Lab printer's LAN Mode FTP server: an
/// implicit-TLS FTPS server on port 990, username "bblp", password = the
/// printer's local Access Code (Settings > Network on the printer).
///
/// Note: this only stages the file on the printer's local storage. Bambu
/// printers don't slice on-device — the file still needs to go through
/// Bambu Studio to become printable G-code.
enum BambuPrinterUploader {
    private static let controlPort: UInt16 = 990

    static func upload(fileURL: URL, to settings: PrinterSettings) async throws {
        guard !settings.host.isEmpty, !settings.accessCode.isEmpty else {
            throw PrinterUploadError.missingSettings
        }

        let control = try await FTPChannel(host: settings.host, port: controlPort)
        defer { control.close() }

        try await control.expect(220)
        try await control.send("USER bblp", expect: 331)
        try await control.send("PASS \(settings.accessCode)", expect: 230)
        try await control.send("PBSZ 0", expect: 200)
        try await control.send("PROT P", expect: 200)
        try await control.send("TYPE I", expect: 200)

        let dataPort = try await control.enterPassiveMode()
        let dataChannel = try await FTPChannel(host: settings.host, port: dataPort)

        try await control.write("STOR \(fileURL.lastPathComponent)")
        try await control.expect(150)

        let fileData = try Data(contentsOf: fileURL)
        try await dataChannel.send(fileData)
        dataChannel.close()

        try await control.expect(226)
        try await control.write("QUIT")
    }
}

/// A TLS-over-TCP connection used for both the FTP control channel and a
/// passive-mode data channel, with small helpers for the line-based FTP
/// command/response protocol.
private final class FTPChannel {
    private let connection: NWConnection
    private var buffer = Data()

    init(host: String, port: UInt16) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PrinterUploadError.connectionFailed("Invalid port \(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: .init()))
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: PrinterUploadError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: PrinterUploadError.connectionFailed("Connection cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func close() {
        connection.cancel()
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: PrinterUploadError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func write(_ command: String) async throws {
        try await send(Data((command + "\r\n").utf8))
    }

    /// Reads response lines until the final line of a reply (FTP multi-line
    /// replies look like "150-...\r\n150 Done\r\n"; only the last line has a
    /// space right after the 3-digit code), and checks it matches `code`.
    @discardableResult
    func expect(_ code: Int) async throws -> String {
        while true {
            let line = try await readLine()
            guard line.count >= 4, let lineCode = Int(line.prefix(3)) else { continue }
            let isFinalLine = line[line.index(line.startIndex, offsetBy: 3)] != "-"
            guard isFinalLine else { continue }
            guard lineCode == code else {
                throw PrinterUploadError.unexpectedResponse(line)
            }
            return line
        }
    }

    func send(_ command: String, expect code: Int) async throws {
        try await write(command)
        try await expect(code)
    }

    /// Sends PASV and parses the data-channel port from a reply like
    /// "227 Entering Passive Mode (192,168,1,100,200,15).".
    func enterPassiveMode() async throws -> UInt16 {
        try await write("PASV")
        let line = try await expect(227)
        guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")") else {
            throw PrinterUploadError.unexpectedResponse(line)
        }
        let numbers = line[line.index(after: open)..<close].split(separator: ",").compactMap { Int($0) }
        guard numbers.count == 6 else {
            throw PrinterUploadError.unexpectedResponse(line)
        }
        return UInt16(numbers[4] * 256 + numbers[5])
    }

    private func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            buffer.append(try await receive())
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: PrinterUploadError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }
}
