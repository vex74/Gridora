import SwiftUI

/// Shared hover / pressed feedback for the light settings panel. The panel
/// used to be `.buttonStyle(.plain)` everywhere: no pointer feedback, no
/// pressed state. This style keeps the existing label geometry untouched and
/// only changes a translucent backing fill and the label's opacity, so no row
/// can shift while the pointer moves. Timing goes through `Motion.quick`,
/// which already collapses to 0.001s when Reduce Motion is on.
struct SettingsButtonStyle: ButtonStyle {
    var hoverFill: Color = DesignTokens.hoverFill
    var radius: CGFloat = DesignTokens.controlRadius

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, hoverFill: hoverFill, radius: radius)
    }

    private struct Chrome: View {
        let configuration: ButtonStyle.Configuration
        let hoverFill: Color
        let radius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(hovering ? hoverFill : .clear)
                }
                .onHover { hovering = $0 }
                .opacity(configuration.isPressed ? 0.62 : 1)
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: configuration.isPressed)
        }
    }
}
