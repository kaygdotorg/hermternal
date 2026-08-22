import SwiftUI

/// A non-interactive identity summary supplied by the composition root.
struct SidebarAccountRow: View {
    let name: String
    let detail: String?
    let accountID: String?
    var body: some View {
        base
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        if let accountID {
            if let detail {
                return Text("\(name), \(detail), account ID \(accountID)")
            }
            return Text("\(name), account ID \(accountID)")
        }
        if let detail {
            return Text("\(name), \(detail)")
        }
        return Text(name)
    }

    /// This row deliberately has no surface of its own. `SidebarBottomEdge`
    /// supplies the masked material that keeps the identity readable while
    /// scrolling rows pass beneath it.
    private var base: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                if let detail {
                    Text(detail)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(accountID ?? name)
    }
}
