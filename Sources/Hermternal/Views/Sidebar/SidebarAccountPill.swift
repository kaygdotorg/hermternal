import SwiftUI

/// A non-interactive identity summary supplied by the composition root.
struct SidebarAccountPill: View {
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

    private var base: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: AppShapeScale.control)
        .help(accountID ?? name)
    }
}
