import SwiftUI

struct SettingsView: View {
    let onSave: () -> Void

    @State private var consumerKey: String = Keychain.get(.instapaperConsumerKey) ?? ""
    @State private var consumerSecret: String = Keychain.get(.instapaperConsumerSecret) ?? ""
    @State private var username: String = Keychain.get(.instapaperUsername) ?? ""
    @State private var password: String = Keychain.get(.instapaperPassword) ?? ""
    @State private var anthropicKey: String = Keychain.get(.anthropicAPIKey) ?? ""
    @State private var firecrawlKey: String = Keychain.get(.firecrawlAPIKey) ?? ""

    @State private var hasToken: Bool = Library.shared.oauthToken != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mini E-Reader Settings")
                .font(.title2).bold()

            Text("All secrets are stored in your macOS Keychain. Nothing is sent anywhere except directly to Instapaper, Anthropic, and the reader.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                sectionHeader("Instapaper OAuth consumer",
                              link: "https://www.instapaper.com/main/request_oauth_consumer_token")
                plainField("Consumer key", text: $consumerKey)
                plainField("Consumer secret", text: $consumerSecret)
            }

            Group {
                Text("Instapaper login")
                    .font(.headline)
                Text(hasToken
                     ? "✓ Token already minted — username/password not needed."
                     : "Used once to mint an OAuth token, then the password is deleted from the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !hasToken {
                    plainField("Email / username", text: $username)
                    plainField("Password", text: $password)
                }
            }

            Group {
                sectionHeader("Anthropic API key", link: "https://console.anthropic.com")
                plainField("sk-ant-...", text: $anthropicKey)
            }

            Group {
                sectionHeader("Firecrawl API key", link: "https://firecrawl.dev")
                plainField("fc-...", text: $firecrawlKey)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .textFieldStyle(.roundedBorder)
    }

    /// Plain text field with every form of autofill/autocorrect/suggestion disabled,
    /// so macOS doesn't pop a password-manager sheet over our Settings window.
    private func plainField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textContentType(.init(rawValue: ""))
            .autocorrectionDisabled(true)
            .disableAutocorrection(true)
    }

    private func sectionHeader(_ title: String, link: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Link("Get one →", destination: URL(string: link)!)
                .font(.caption)
        }
    }

    private var canSave: Bool {
        !consumerKey.isEmpty &&
        !consumerSecret.isEmpty &&
        !anthropicKey.isEmpty &&
        !firecrawlKey.isEmpty &&
        (hasToken || (!username.isEmpty && !password.isEmpty))
    }

    private func save() {
        Keychain.set(consumerKey, for: .instapaperConsumerKey)
        Keychain.set(consumerSecret, for: .instapaperConsumerSecret)
        Keychain.set(anthropicKey, for: .anthropicAPIKey)
        Keychain.set(firecrawlKey, for: .firecrawlAPIKey)
        if !hasToken {
            Keychain.set(username, for: .instapaperUsername)
            Keychain.set(password, for: .instapaperPassword)
        }
        // Window close is handled by the host (AppDelegate) via onSave.
        onSave()
    }
}
