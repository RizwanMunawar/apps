import SwiftUI

struct ClassPickerView: View {
    @ObservedObject var viewModel: BlurSessionViewModel
    let palette: Palette
    @State private var query = ""
    @Environment(\.sidebarZoom) private var zoom

    private var filtered: [DetectableClass] {
        guard !query.isEmpty else { return DetectableClass.all }
        return DetectableClass.all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * zoom) {
            HStack {
                Text("Blur these classes").sectionLabel(palette, zoom: zoom)
                Spacer()
                Text("\(viewModel.selectedClassIndices.count) selected")
                    .zoomedFont(11, weight: .semibold, design: .rounded, zoom: zoom)
                    .foregroundStyle(palette.accent)
            }

            HStack(spacing: 8) {
                Button("Select all") { viewModel.selectAllClasses() }
                    .buttonStyle(.plain)
                    .zoomedFont(11.5, weight: .medium, zoom: zoom)
                    .foregroundStyle(palette.accent)
                Text("·").foregroundStyle(palette.textSecondary)
                Button("Clear") { viewModel.clearAllClasses() }
                    .buttonStyle(.plain)
                    .zoomedFont(11.5, weight: .medium, zoom: zoom)
                    .foregroundStyle(palette.textSecondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(palette.textSecondary)
                TextField("Search 80 classes…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * zoom))
                    .foregroundStyle(palette.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8 * zoom)
            .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.border))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { item in
                        classRow(item)
                    }
                }
            }
            .frame(height: 320 * zoom)
        }
    }

    private func classRow(_ item: DetectableClass) -> some View {
        let isSelected = viewModel.selectedClassIndices.contains(item.index)
        return Button {
            viewModel.toggleClass(item.index)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? palette.accent : Color.clear)
                        .frame(width: 16 * zoom, height: 16 * zoom)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(isSelected ? .clear : palette.border, lineWidth: 1.2)
                        )
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9 * zoom, weight: .black))
                            .foregroundStyle(palette.onAccent)
                    }
                }
                Image(systemName: item.glyph)
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(isSelected ? palette.accent : palette.textSecondary.opacity(0.7))
                    .frame(width: 16 * zoom)
                Text(item.displayName)
                    .zoomedFont(12, weight: isSelected ? .semibold : .regular, design: .rounded, zoom: zoom)
                    .foregroundStyle(isSelected ? palette.textPrimary : palette.textPrimary.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6 * zoom)
            .background(isSelected ? palette.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
