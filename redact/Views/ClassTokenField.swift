import AppCore
import SwiftUI

/// Picking what to hide, as a list of things you have added rather than a menu you open.
///
/// A dropdown hid the answer to the only question that matters here — what is currently being
/// covered — behind a click. Here the chosen classes are always on screen as tokens you can
/// remove, with a search box to add more and a few one-tap suggestions for the usual ones.
struct ClassTokenField: View {
    @ObservedObject var viewModel: BlurSessionViewModel
    let palette: Palette

    @State private var query = ""

    /// Offered when nothing is being typed: the classes people actually reach for.
    private let suggested = ["person", "car", "cell phone", "laptop", "dog", "cat"]

    private var selected: [DetectableClass] {
        viewModel.classes
            .filter { viewModel.selectedClassIndices.contains($0.index) }
            .sorted { $0.index < $1.index }
    }

    /// How many suggestions there is room for. The well holds two rows, so the count shrinks as
    /// selections fill it: showing a row that gets sliced in half by the edge looks broken, and
    /// the point of this bar is that nothing hides.
    private var suggestionLimit: Int {
        max(1, 4 - selected.count)
    }

    private var matches: [DetectableClass] {
        let unselected = viewModel.classes.filter { !viewModel.selectedClassIndices.contains($0.index) }
        guard !query.isEmpty else {
            return Array(suggested.compactMap { name in unselected.first { $0.name == name } }.prefix(suggestionLimit))
        }
        return Array(unselected.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(suggestionLimit + 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(AppFont.text(11))
                    .foregroundStyle(palette.textSecondary)
                TextField("Add object", text: $query)
                    .textFieldStyle(.plain)
                    .font(AppFont.text(12))
                    .foregroundStyle(palette.textPrimary)
                    .onSubmit {
                        // Enter adds the top match, so adding several in a row never needs the mouse.
                        if let first = matches.first {
                            viewModel.toggleClass(first.index)
                            query = ""
                        }
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(AppFont.text(10))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.border))

            // Capped and scrollable: selecting all 80 classes must not make the bar grow.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    if !selected.isEmpty {
                        TokenFlow(spacing: 5) {
                            ForEach(selected) { item in
                                token(item, isSelected: true)
                            }
                        }
                    }
                    if !matches.isEmpty {
                        TokenFlow(spacing: 5) {
                            ForEach(matches) { item in
                                token(item, isSelected: false)
                            }
                        }
                    } else if !query.isEmpty {
                        Text("Nothing matches that")
                            .font(AppFont.text(10.5))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 84)
        }
    }

    private func token(_ item: DetectableClass, isSelected: Bool) -> some View {
        Button {
            viewModel.toggleClass(item.index)
            if !isSelected { query = "" }
        } label: {
            HStack(spacing: 5) {
                Text(item.displayName)
                    .font(AppFont.text(11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? palette.accent : palette.textSecondary)
                Image(systemName: isSelected ? "xmark" : "plus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isSelected ? palette.accent : palette.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? palette.accent.opacity(0.10) : palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? palette.accent.opacity(0.6) : palette.border)
            )
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Stop hiding \(item.displayName)" : "Also hide \(item.displayName)")
    }
}

/// Wraps its children onto as many rows as they need. `LazyVGrid` can't do this, because token
/// widths vary with the label and a fixed column grid would leave ragged gaps.
struct TokenFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        let rows = layout(subviews: subviews, in: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in layout(subviews: subviews, in: bounds.width) {
            subviews[row.index].place(
                at: CGPoint(x: bounds.minX + row.x, y: bounds.minY + row.y),
                proposal: .unspecified
            )
        }
    }

    private struct Placed {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
    }

    private func layout(subviews: Subviews, in width: CGFloat) -> [Placed] {
        var placed: [Placed] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            placed.append(Placed(index: index, x: x, y: y, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return placed
    }
}
