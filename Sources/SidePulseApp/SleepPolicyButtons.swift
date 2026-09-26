import SwiftUI
import SidePulseCore

/// Drawn by hand because menus render standard controls as inactive, which grays out a segmented control's
/// accent-colored selection.
struct SleepPolicyButtons: View {
    let selection: SleepPolicy
    let select: (SleepPolicy) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(SleepPolicy.allCases, id: \.self) { policy in
                Button(policy.label) { select(policy) }
                    .buttonStyle(PolicyButtonStyle(selected: policy == selection))
                    .accessibilityAddTraits(policy == selection ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MenuText.keepAwake)
    }
}

private struct PolicyButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill(pressed: configuration.isPressed)))
            .contentShape(Rectangle())
    }

    private func fill(pressed: Bool) -> Color {
        if selected { return Color.accentColor.opacity(pressed ? 0.8 : 1) }
        return Color.primary.opacity(pressed ? 0.22 : 0.1)
    }
}
