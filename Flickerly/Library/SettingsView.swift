import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .dark
    private let privacyPolicyURL = URL(string: "https://docs.google.com/document/d/133g1EmOIsIxwXrFyK4BgxO8l-LYfl71YzTPs99P8vpM")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(AppTypography.font(size: 18, weight: .medium))
                        .frame(width: 46, height: 46)
                        .background(Palette.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to collections")
                .accessibilityIdentifier("backFromSettings")

                Text("Settings")
                    .font(AppTypography.font(size: 18, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("settingsTitle")

                Color.clear
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 24)
            .padding(.top, 20)

            ScrollView {
                VStack(spacing: 16) {
                    appearanceCard
                    privacyPolicyCard
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            versionFooter
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var versionFooter: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return Text("Version \(version)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(Palette.background)
            .accessibilityIdentifier("appVersion")
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(AppTypography.font(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                ForEach(AppTheme.allCases) { option in
                    Button {
                        theme = option
                    } label: {
                        Label(option.title, systemImage: option.symbol)
                            .font(AppTypography.font(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(theme == option ? Palette.background : Palette.ink)
                            .background(
                                theme == option ? Palette.ink : Palette.surface,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.title) theme")
                    .accessibilityValue(theme == option ? "Selected" : "Not selected")
                    .accessibilityAddTraits(theme == option ? .isSelected : [])
                    .accessibilityIdentifier("theme-\(option.rawValue)")
                }
            }
        }
        .padding(20)
        .background(Palette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private var privacyPolicyCard: some View {
        Link(destination: privacyPolicyURL) {
            HStack(spacing: 16) {
                Text("Privacy policy")
                    .font(AppTypography.font(size: 17, weight: .semibold))
                Spacer()
                SettingsExternalLinkIcon()
                    .fill(Palette.ink)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(20)
            .background(Palette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the privacy policy in your browser")
        .accessibilityIdentifier("privacyPolicyButton")
    }
}

/// Matches the external-link arrow used by Flytly's privacy card.
private struct SettingsExternalLinkIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var arrow = Path()
        arrow.move(to: point(4, 20))
        arrow.addLine(to: point(20, 4))
        arrow.move(to: point(8, 4))
        arrow.addLine(to: point(20, 4))
        arrow.addLine(to: point(20, 16))
        return arrow.strokedPath(StrokeStyle(lineWidth: 3 * scale, lineCap: .butt, lineJoin: .round))
    }
}
