import SwiftUI

struct PrinterSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var accessCode: String
    @State private var forgotPrinter = false
    private let savedHost: String?
    let onSave: (PrinterSettings) -> Void

    init(current: PrinterSettings?, onSave: @escaping (PrinterSettings) -> Void) {
        _host = State(initialValue: current?.host ?? "")
        _accessCode = State(initialValue: current?.accessCode ?? "")
        savedHost = current?.host
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Printer IP address", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Access Code", text: $accessCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Find both on the printer: Settings > Network > LAN Only Mode. Your phone and the printer must be on the same Wi-Fi network. \(PrinterUploadError.lanModeHint) The file still needs to be sliced in Bambu Studio before the printer can print it — this only stages it on the printer's storage.")
                }

                if let savedHost, !savedHost.isEmpty {
                    Section {
                        Button("Forget Printer", role: .destructive) {
                            PrinterCertificatePins.forget(host: savedHost)
                            forgotPrinter = true
                        }
                        .disabled(forgotPrinter)
                    } footer: {
                        Text(forgotPrinter
                            ? "Forgotten. The printer's certificate will be trusted again on the next successful connection."
                            : "U-Scan3D remembers the printer's security certificate after the first connection. Use this after resetting or replacing the printer.")
                    }
                }
            }
            .navigationTitle("Bambu X1 Carbon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let settings = PrinterSettings(host: host, accessCode: accessCode)
                        settings.save()
                        onSave(settings)
                        dismiss()
                    }
                    .disabled(host.isEmpty || accessCode.isEmpty)
                }
            }
        }
    }
}
