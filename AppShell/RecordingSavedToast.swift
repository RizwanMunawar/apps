import AppCore
import SwiftUI

/// Confirms where a finished recording went, without stealing focus.
///
/// A modal here would interrupt the thing the recording was made of — often a long file job that
/// is still running. This sits in the corner and waits.
struct RecordingSavedToast: View {
    let url: URL
    let palette: Palette
    @ObservedObject var recorder: SessionRecorder

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(palette.live)

            VStack(alignment: .leading, spacing: 1) {
                Text("Recording saved")
                    .font(AppFont.text(12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(url.lastPathComponent)
                    .font(AppFont.text(11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 220, alignment: .leading)

            Button("Show") { recorder.revealLastRecording() }
                .buttonStyle(SecondaryButtonStyle(palette: palette))

            Button {
                recorder.dismissLastRecording()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }
}
