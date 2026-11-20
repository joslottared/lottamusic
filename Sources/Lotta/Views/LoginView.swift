import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(.tint)
                        Text("Lotta").font(.largeTitle.bold())
                        Text("Tu música de Jellyfin, contigo.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("192.168.1.10:8096 o https://…", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Servidor")
                }

                Section {
                    TextField("Usuario", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Contraseña", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Cuenta")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Conectar").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || server.isEmpty || username.isEmpty)
                }
            }
        }
    }

    private func submit() async {
        busy = true
        error = nil
        do {
            try await model.login(server: server, username: username, password: password)
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
