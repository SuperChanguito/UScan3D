import SwiftUI

struct PrinterSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var accessCode: String
    let onSave: (PrinterSettings) -> Void

    init(current: PrinterSettings?, onSave: @escaping (PrinterSettings) -> Void) {
        _host = State(initialValue: current?.host ?? "")
        _accessCode = State(initialValue: current?.accessCode ?? "")
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
                    Text("Find both on the printer: Settings > Network > LAN Only Mode. Your phone and the printer must be on the same Wi-Fi network. The file still needs to be sliced in Bambu Studio before the printer can print it — this only stages it on the printer's storage.")
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
