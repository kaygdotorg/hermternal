import SwiftUI

/// A non-interactive identity line supplied by the composition root.
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

    /// Nothing is drawn behind this row. The capsule that used to sit here was
    /// an app-owned surface standing in for hierarchy, and on the sidebar's
    /// frost it read as a gray chip. Weight and level supply that hierarchy
    /// instead. macOS `.headline` is 13 pt bold on a 16 pt line, the same size
    /// and leading as `.body`, so identity reads as identity without moving the
    /// row's metrics and without a shape the OS never draws. The account name
    /// moves one step up, from `.caption` at 10/13 to `.subheadline` at 11/14,
    /// the subordinate line of a two-line system row, because it lost the
    /// capsule's local contrast floor. All three are semantic text styles, so
    /// they track the system's own scale rather than a tuned point size.
    ///
    /// Inset belongs to the container, so the internal padding went with the
    /// capsule: both call sites already pad this row, and dropping it also
    /// settles the glyph onto the same column the session rows use. The
    /// gradient mask in `SidebarView` separates this identity from those rows.
    private var base: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(gateway)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                if let account {
                    Text(account)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            }
        } icon: {
            // Mirrors `SessionRow`: the glyph takes the row's own foreground
            // and adds no level of its own. `.secondary` measured 4.5:1 there
            // against a settled sidebar backdrop, and less once the window
            // frost let the desktop through; the capsule that used to back
            // this mark is now gone, so a dimmed level has even less to sit
            // on. Monochrome for the same measured reason: `person.crop.circle`
            // is multi-layer, and hierarchical resolution draws its lower
            // layers further reduced, which costs the mark most of its ink.
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .symbolRenderingMode(.monochrome)
        }
        .help(accountID ?? gateway)
    }
}
