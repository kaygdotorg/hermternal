import SwiftUI

/// A non-interactive identity pill supplied by the composition root.
///
/// `gateway` is the primary line. `account` is the human-readable account
/// name, if the gateway supplies one. `accountID` goes to the tooltip and to
/// VoiceOver only. `accountID` never takes a visible line, because an opaque
/// identifier is not a name.
struct SidebarAccountRow: View {
    let gateway: String
    let account: String?
    let accountID: String?
    var body: some View {
        base
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        if let accountID {
            if let account {
                return Text("Gateway \(gateway), \(account), account ID \(accountID)")
            }
            return Text("Gateway \(gateway), account ID \(accountID)")
        }
        if let account {
            return Text("Gateway \(gateway), \(account)")
        }
        return Text("Gateway \(gateway)")
    }

    /// SwiftUI has no static system pill. Every capsule control style is a
    /// button, a menu, or a toggle, and this identity is not interactive. The
    /// user approved this app-drawn capsule. It uses one semantic fill and the
    /// shared shape token, so it adds no radius, border, shadow, or press
    /// state. `SidebarBottomEdge` still supplies the masked material behind
    /// the pill. That material keeps the pill readable while rows scroll
    /// beneath it.
    private var base: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(gateway)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                if let account {
                    Text(account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            }
        } icon: {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: AppShapeScale.control)
        .help(accountID ?? gateway)
    }
}
