import CryptoKit
import Foundation
import Network
import Security

/// The printer's address (UserDefaults) and access code (Keychain — it's
/// the printer's LAN password).
struct PrinterSettings: Equatable {
    var host: String
    var accessCode: String

    private static let hostKey = "com.mrgrisafe.UScan3D.printerHost"
    private static let accessCodeService = "com.mrgrisafe.UScan3D.printerAccessCode"
    private static let accessCodeAccount = "bblp"
    /// Earlier versions stored both fields as JSON in UserDefaults.
    private static let legacyUserDefaultsKey = "com.mrgrisafe.UScan3D.printerSettings"

    static func load() -> PrinterSettings? {
        migrateLegacySettings()
        guard let host = UserDefaults.standard.string(forKey: hostKey), !host.isEmpty else { return nil }
        let accessCode = Keychain.data(service: accessCodeService, account: accessCodeAccount)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return PrinterSettings(host: host, accessCode: accessCode)
    }

    @discardableResult
    func save() -> Bool {
        UserDefaults.standard.set(host, forKey: Self.hostKey)
        return Keychain.set(Data(accessCode.utf8), service: Self.accessCodeService, account: Self.accessCodeAccount)
    }

    /// Moves settings saved by earlier versions into the Keychain, then
    /// removes the plain-text copy (only once the Keychain write succeeded).
    private static func migrateLegacySettings() {
        guard let data = UserDefaults.standard.data(forKey: legacyUserDefaultsKey) else { return }
        struct LegacySettings: Decodable {
            var host: String
            var accessCode: String
        }
        if let legacy = try? JSONDecoder().decode(LegacySettings.self, from: data) {
            guard PrinterSettings(host: legacy.host, accessCode: legacy.accessCode).save() else { return }
        }
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
    }
}

enum PrinterUploadError: LocalizedError {
    case missingSettings
    case cannotReachPrinter
    case connectionFailed(String)
    case connectionClosed
    case timedOut(String)
    case wrongAccessCode
    case certificateChanged
    case dataConnectionRejected(String)
    case unexpectedResponse(String)

    static let lanModeHint = "Recent Bambu firmware may require LAN Only Mode and/or Developer Mode to be turned on (printer: Settings > Network) before third-party apps can connect."

    var errorDescription: String? {
        switch self {
        case .missingSettings:
            return "Set up the printer's IP address and access code first."
        case .cannotReachPrinter:
            return "Can't reach the printer — check the IP address and that your phone is on the same Wi-Fi. \(Self.lanModeHint)"
        case .connectionFailed(let message):
            return "Couldn't connect to the printer: \(message). \(Self.lanModeHint)"
        case .connectionClosed:
            return "The printer closed the connection."
        case .timedOut(let activity):
            return "The printer stopped responding while \(activity)."
        case .wrongAccessCode:
            return "Wrong access code. Check it on the printer under Settings > Network (it changes if LAN Only Mode is toggled)."
        case .certificateChanged:
            return "The printer's security certificate changed. If you reset or replaced the printer, tap Forget Printer in printer settings."
        case .dataConnectionRejected(let detail):
            return "The printer accepted the login but refused the file-transfer connection (\(detail)). Bambu's FTPS server requires that connection to reuse the login's TLS session, which iOS may not support. Send the file with Bambu Studio or Bambu Handy instead."
        case .unexpectedResponse(let message):
            return "Unexpected response from the printer: \(message)"
        }
    }
}

/// Trust-on-first-use pins of each printer's self-signed TLS certificate
/// (SHA-256 of the leaf certificate), kept in the Keychain by host.
enum PrinterCertificatePins {
    private static let service = "com.mrgrisafe.UScan3D.printerCertificate"

    static func pin(for host: String) -> Data? {
        Keychain.data(service: service, account: host)
    }

    static func save(_ fingerprint: Data, for host: String) {
        Keychain.set(fingerprint, service: service, account: host)
    }

    static func forget(host: String) {
        Keychain.delete(service: service, account: host)
    }
}

/// Uploads a print file to a Bambu Lab printer's LAN Mode FTP server: an
/// implicit-TLS FTPS server (vsftpd) on port 990, username "bblp", password =
/// the printer's local Access Code (Settings > Network on the printer).
///
/// Note: this only stages the file on the printer's local storage. Bambu
/// printers don't slice on-device — the file still needs to go through
/// Bambu Studio to become printable G-code.
///
/// Known limitation: vsftpd requires the data connection to resume the
/// control connection's TLS session. Network.framework has resumption
/// enabled here and both connections share one TLS options object and
/// server name, but Apple DTS has stated Network.framework offers no way to
/// force session-ID reuse across connections (developer forums thread
/// 759316). If the printer rejects the data connection, the user gets a
/// specific `dataConnectionRejected` error rather than a hang.
enum BambuPrinterUploader {
    private static let controlPort: UInt16 = 990
    private static let connectTimeout: TimeInterval = 10
    private static let replyTimeout: TimeInterval = 30

    static func upload(fileURL: URL, to settings: PrinterSettings) async throws {
        guard !settings.host.isEmpty, !settings.accessCode.isEmpty else {
            throw PrinterUploadError.missingSettings
        }
        let fileData = try Data(contentsOf: fileURL)
        // Allow for a slow link (~50 KB/s) on top of a fixed allowance.
        let uploadTimeout = 30 + Double(fileData.count) / 50_000

        let certificateCheck = CertificateCheck(host: settings.host)
        let tls = makeTLSOptions(host: settings.host, certificateCheck: certificateCheck)

        let control = try FTPChannel(
            host: settings.host, port: controlPort, tls: tls,
            certificateCheck: certificateCheck, replyTimeout: replyTimeout)
        defer { control.close() }
        try await control.waitUntilReady(timeout: connectTimeout)

        try await control.expect(220)
        try await control.send("USER bblp", expect: 331)
        let pass = try await control.command("PASS \(settings.accessCode)")
        switch pass.code {
        case 230: break
        case 530: throw PrinterUploadError.wrongAccessCode
        default: throw PrinterUploadError.unexpectedResponse(pass.line)
        }
        // The access code proved this is the user's printer: pin its
        // certificate now if this is the first successful connection.
        certificateCheck.pinIfFirstConnection()

        try await control.send("PBSZ 0", expect: 200)
        try await control.send("PROT P", expect: 200)
        try await control.send("TYPE I", expect: 200)

        let dataPort = try await control.enterPassiveMode()
        // Start connecting now, but don't wait for the TLS handshake: vsftpd
        // only accepts the data connection (and handshakes) after STOR.
        let dataChannel = try FTPChannel(
            host: settings.host, port: dataPort, tls: tls,
            certificateCheck: certificateCheck, replyTimeout: replyTimeout)
        defer { dataChannel.close() }

        let stor = try await control.command("STOR \(fileURL.lastPathComponent)")
        switch stor.code {
        case 125, 150: break
        case 425, 426, 522: throw PrinterUploadError.dataConnectionRejected(stor.line)
        default: throw PrinterUploadError.unexpectedResponse(stor.line)
        }

        do {
            try await dataChannel.waitUntilReady(timeout: connectTimeout)
        } catch PrinterUploadError.certificateChanged {
            throw PrinterUploadError.certificateChanged
        } catch {
            // vsftpd explains a refused data connection on the control
            // channel (e.g. "522 SSL connection failed: session reuse
            // required"); include that if it arrives promptly.
            let reply = try? await control.readReply(timeout: 5)
            throw PrinterUploadError.dataConnectionRejected(reply?.line ?? error.localizedDescription)
        }

        try await dataChannel.sendFile(fileData, timeout: uploadTimeout)
        dataChannel.close()

        let done = try await control.readReply(timeout: uploadTimeout)
        switch done.code {
        case 226, 250: break
        case 425, 426, 451, 522: throw PrinterUploadError.dataConnectionRejected(done.line)
        default: throw PrinterUploadError.unexpectedResponse(done.line)
        }
        try? await control.write("QUIT")
    }

    /// One TLS configuration shared by the control and data connections
    /// (same server name, resumption on) so Network.framework has every
    /// chance to resume the session; TLS 1.2+; certificate checked against
    /// the trust-on-first-use pin instead of a CA chain (Bambu printers use
    /// self-signed certificates).
    private static func makeTLSOptions(host: String, certificateCheck: CertificateCheck) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(options, true)
        sec_protocol_options_set_tls_server_name(options, host)
        sec_protocol_options_set_verify_block(options, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
            complete(certificateCheck.accept(fingerprint))
        }, DispatchQueue(label: "com.mrgrisafe.UScan3D.tls-verify"))
        return tls
    }
}

/// Trust-on-first-use state for one upload: compares the presented
/// certificate against the stored pin, and remembers it for pinning once the
/// login succeeds.
private final class CertificateCheck: @unchecked Sendable {
    let host: String
    private let lock = NSLock()
    private var observedFingerprint: Data?
    private var mismatched = false

    init(host: String) {
        self.host = host
    }

    var didMismatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mismatched
    }

    func accept(_ fingerprint: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let pinned = PrinterCertificatePins.pin(for: host) {
            if pinned == fingerprint { return true }
            mismatched = true
            return false
        }
        // Unpinned: accept the first certificate seen in this upload, and
        // require the data connection to present the same one.
        if let observedFingerprint {
            return observedFingerprint == fingerprint
        }
        observedFingerprint = fingerprint
        return true
    }

    func pinIfFirstConnection() {
        lock.lock()
        defer { lock.unlock() }
        guard PrinterCertificatePins.pin(for: host) == nil, let observedFingerprint else { return }
        PrinterCertificatePins.save(observedFingerprint, for: host)
    }
}

/// Resumes a continuation exactly once, whichever of the operation or its
/// timeout finishes first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

/// A TLS-over-TCP connection used for both the FTP control channel and a
/// passive-mode data channel, with small helpers for the line-based FTP
/// command/response protocol. Every wait has a timeout.
private final class FTPChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let certificateCheck: CertificateCheck
    private let replyTimeout: TimeInterval
    private var buffer = Data()

    // Accessed only on `queue`.
    private var state: NWConnection.State = .setup
    private var readyWaiter: ResumeOnce<Void>?

    /// Starts connecting immediately; use `waitUntilReady` to wait for the
    /// TLS handshake.
    init(host: String, port: UInt16, tls: NWProtocolTLS.Options,
         certificateCheck: CertificateCheck, replyTimeout: TimeInterval) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PrinterUploadError.connectionFailed("Invalid port \(port)")
        }
        self.queue = DispatchQueue(label: "com.mrgrisafe.UScan3D.ftp.\(port)")
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: tls))
        self.certificateCheck = certificateCheck
        self.replyTimeout = replyTimeout

        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.start(queue: queue)
    }

    func close() {
        connection.cancel()
    }

    private func handle(_ newState: NWConnection.State) {
        state = newState
        switch newState {
        case .ready:
            readyWaiter?.resume(with: .success(()))
            readyWaiter = nil
        case .failed(let error):
            readyWaiter?.resume(with: .failure(failure(for: error)))
            readyWaiter = nil
        case .cancelled:
            readyWaiter?.resume(with: .failure(PrinterUploadError.connectionClosed))
            readyWaiter = nil
        default:
            // .waiting (e.g. host unreachable) keeps retrying; the timeout
            // in waitUntilReady turns it into a failure.
            break
        }
    }

    private func failure(for error: NWError) -> PrinterUploadError {
        certificateCheck.didMismatch
            ? .certificateChanged
            : .connectionFailed(error.localizedDescription)
    }

    func waitUntilReady(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let waiter = ResumeOnce(continuation)
            queue.async {
                switch self.state {
                case .ready:
                    waiter.resume(with: .success(()))
                case .failed(let error):
                    waiter.resume(with: .failure(self.failure(for: error)))
                case .cancelled:
                    waiter.resume(with: .failure(PrinterUploadError.connectionClosed))
                default:
                    self.readyWaiter = waiter
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        if waiter.resume(with: .failure(PrinterUploadError.cannotReachPrinter)) {
                            self.readyWaiter = nil
                            self.connection.cancel()
                        }
                    }
                }
            }
        }
    }

    /// Runs `operation`, failing with `timeoutError` (and cancelling the
    /// connection) if it hasn't finished within `timeout` seconds.
    private func withTimeout<T>(
        _ timeout: TimeInterval,
        _ timeoutError: PrinterUploadError,
        returning: T.Type = T.self,
        _ operation: @escaping (@escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.resume(with: .failure(timeoutError)) {
                    self.connection.cancel()
                }
            }
            operation { result in
                once.resume(with: result)
            }
        }
    }

    private func send(_ data: Data, isFinal: Bool, timeout: TimeInterval) async throws {
        try await withTimeout(timeout, .timedOut("sending data"), returning: Void.self) { finish in
            self.connection.send(
                content: data,
                contentContext: isFinal ? .finalMessage : .defaultMessage,
                isComplete: isFinal,
                completion: .contentProcessed { error in
                    if let error {
                        finish(.failure(PrinterUploadError.connectionFailed(error.localizedDescription)))
                    } else {
                        finish(.success(()))
                    }
                })
        }
    }

    /// Streams the file in chunks; the last chunk is sent with
    /// isComplete: true as the final message, which closes the stream so
    /// the server knows the transfer is done.
    func sendFile(_ data: Data, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let chunkSize = 256 * 1024
        var offset = 0
        repeat {
            let end = min(offset + chunkSize, data.count)
            let remaining = max(1, deadline.timeIntervalSinceNow)
            try await send(data.subdata(in: offset..<end), isFinal: end == data.count, timeout: remaining)
            offset = end
        } while offset < data.count
    }

    func write(_ command: String) async throws {
        try await withTimeout(replyTimeout, .timedOut("sending a command"), returning: Void.self) { finish in
            self.connection.send(content: Data((command + "\r\n").utf8), completion: .contentProcessed { error in
                if let error {
                    finish(.failure(PrinterUploadError.connectionFailed(error.localizedDescription)))
                } else {
                    finish(.success(()))
                }
            })
        }
    }

    /// Reads response lines until the final line of a reply (FTP multi-line
    /// replies look like "150-...\r\n150 Done\r\n"; only the last line has a
    /// space right after the 3-digit code).
    func readReply(timeout: TimeInterval? = nil) async throws -> (code: Int, line: String) {
        while true {
            let line = try await readLine(timeout: timeout ?? replyTimeout)
            guard line.count >= 4, let code = Int(line.prefix(3)) else { continue }
            let isFinalLine = line[line.index(line.startIndex, offsetBy: 3)] != "-"
            guard isFinalLine else { continue }
            return (code, line)
        }
    }

    func command(_ command: String) async throws -> (code: Int, line: String) {
        try await write(command)
        return try await readReply()
    }

    @discardableResult
    func expect(_ code: Int) async throws -> String {
        let reply = try await readReply()
        guard reply.code == code else {
            throw PrinterUploadError.unexpectedResponse(reply.line)
        }
        return reply.line
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

    private func readLine(timeout: TimeInterval) async throws -> String {
        while true {
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            buffer.append(try await receive(timeout: timeout))
        }
    }

    private func receive(timeout: TimeInterval) async throws -> Data {
        try await withTimeout(timeout, .timedOut("waiting for a reply"), returning: Data.self) { finish in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    finish(.failure(PrinterUploadError.connectionFailed(error.localizedDescription)))
                } else if let data, !data.isEmpty {
                    finish(.success(data))
                } else {
                    // Complete/closed with nothing left to read. Returning
                    // empty Data here used to make readLine spin forever.
                    finish(.failure(PrinterUploadError.connectionClosed))
                }
            }
        }
    }
}
