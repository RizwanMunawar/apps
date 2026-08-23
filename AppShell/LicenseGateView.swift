import AppCore
import SwiftUI

/// What the window shows when the app is not licensed to run.
///
/// Deliberately a wall, not a nag: past the trial there is no "continue anyway". The two ways
/// forward are the two real ones — start the trial, or paste a key.
struct LicenseGateView: View {
    @ObservedObject var licensing: LicenseManager
    let palette: Palette

    private enum Route {
        case choose
        case trial
        case key
    }

    @State private var route: Route = .choose
    @State private var email = ""
    @State private var password = ""
    @State private var pastedKey = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                header

                switch route {
                case .choose: chooser
                case .trial: trialForm
                case .key: keyForm
                }

                if let message = licensing.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(AppFont.text(12))
                        .foregroundStyle(palette.warningText)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.warningBackground, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(28)
            .frame(width: 460)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14).strokeBorder(palette.border, lineWidth: 1)
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppFont.display(20))
                .foregroundStyle(palette.textPrimary)
            Text(subtitle)
                .font(AppFont.text(13))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch licensing.state {
        case .trialExpired: return "Your trial has ended"
        case .licenseExpired: return "Your license has expired"
        case .revoked: return "This license was withdrawn"
        case .clockTampered: return "Check your Mac's date"
        default: return "Activate Redact"
        }
    }

    private var subtitle: String {
        switch licensing.state {
        case .trialExpired:
            return "The 14-day trial on this Mac is over. Enter a license key to carry on."
        case .licenseExpired:
            return "Redact stops here until the license is renewed. Your files are untouched."
        case .revoked:
            return "This key is no longer valid. If that's unexpected, contact your administrator."
        case .clockTampered:
            return "Your Mac's clock is set earlier than the last time Redact ran, so licence "
                 + "dates can't be trusted. Set the date and time correctly, then reopen Redact."
        default:
            return "Redact runs on this Mac once it's licensed. Start a 14-day trial, or paste a "
                 + "key you've been given."
        }
    }

    // MARK: - Routes

    @ViewBuilder
    private var chooser: some View {
        if case .clockTampered = licensing.state {
            Button("Check again") { licensing.refresh() }
                .buttonStyle(PrimaryButtonStyle(palette: palette))
        } else {
            VStack(spacing: 10) {
                if canStartTrial {
                    Button("Start a 14-day trial") { route = .trial; licensing.errorMessage = nil }
                        .buttonStyle(PrimaryButtonStyle(palette: palette))
                        .frame(maxWidth: .infinity)
                }
                Button("I have a license key") { route = .key; licensing.errorMessage = nil }
                    .buttonStyle(SecondaryButtonStyle(palette: palette))
                    .frame(maxWidth: .infinity)
            }

            Text("Licenses come from your RizwanAI account. Trials need an account too — one "
                 + "trial per account.")
                .font(AppFont.text(11))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A trial is only worth offering when this Mac has not already used one up.
    private var canStartTrial: Bool {
        switch licensing.state {
        case .trialExpired, .licenseExpired, .revoked: return false
        default: return true
        }
    }

    private var trialForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Email", text: $email, prompt: "you@company.com")
            secureField("Password", text: $password)

            HStack(spacing: 8) {
                Button("Back") { route = .choose; licensing.errorMessage = nil }
                    .buttonStyle(SecondaryButtonStyle(palette: palette))
                Button(licensing.isWorking ? "Starting…" : "Start trial") {
                    Task { await licensing.startTrial(email: email, password: password) }
                }
                .buttonStyle(PrimaryButtonStyle(palette: palette))
                .disabled(licensing.isWorking || email.isEmpty || password.isEmpty)
            }

            Text("Sign in with your RizwanAI account. Don't have one? Ask for an invitation.")
                .font(AppFont.text(11))
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var keyForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("License key")
                .font(AppFont.text(12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            TextEditor(text: $pastedKey)
                .font(AppFont.mono(11))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 92)
                .background(palette.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.border, lineWidth: 1))

            HStack(spacing: 8) {
                Button("Back") { route = .choose; licensing.errorMessage = nil }
                    .buttonStyle(SecondaryButtonStyle(palette: palette))
                Button(licensing.isWorking ? "Checking…" : "Activate") {
                    Task { await licensing.activate(pastedKey: pastedKey) }
                }
                .buttonStyle(PrimaryButtonStyle(palette: palette))
                .disabled(licensing.isWorking || pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Starts with RZAI1. Copy the whole key from your account page.")
                .font(AppFont.text(11))
                .foregroundStyle(palette.textSecondary)
        }
    }

    // MARK: - Fields

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(AppFont.text(12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(AppFont.text(13))
                .padding(8)
                .background(palette.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.border, lineWidth: 1))
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(AppFont.text(12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            SecureField("", text: text)
                .textFieldStyle(.plain)
                .font(AppFont.text(13))
                .padding(8)
                .background(palette.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.border, lineWidth: 1))
        }
    }
}
