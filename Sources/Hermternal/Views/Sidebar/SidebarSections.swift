import SwiftUI
import HermternalCore

struct SidebarSections: View {
    let sections: [SidebarSection]
    let onOpen: (ChatSession) -> Void
    let onPin: (ChatSession) -> Void
    let onArchive: (ChatSession) -> Void
    let onRename: (ChatSession) -> Void

    var body: some View {
        ForEach(sections) { section in
            sectionView(section)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SidebarSection) -> some View {
        switch section.kind {
        case .ungrouped:
            Section {
                rows(for: section)
            }
        default:
            Section {
                rows(for: section)
            } header: {
                Text(sectionTitle(for: section.kind))
            }
        }
    }

    @ViewBuilder
    private func rows(for section: SidebarSection) -> some View {
        ForEach(section.rows) { row in
            SessionRowItem(
                session: row.session,
                onOpen: onOpen,
                onPin: onPin,
                onArchive: onArchive,
                onRename: onRename
            )
            .tag(row.sessionID)
        }
    }

    private func sectionTitle(for kind: SidebarSectionKind) -> String {
        switch kind {
        case .schedules:
            "Schedules"
        case .pinned:
            "Pinned"
        case .folder(_, let name):
            name
        case .bucket(let bucket):
            dateBucketTitle(bucket)
        case .ungrouped:
            ""
        }
    }

    private func dateBucketTitle(_ bucket: DateBucket) -> String {
        switch bucket {
        case .today:
            "Today"
        case .yesterday:
            "Yesterday"
        case .previousSevenDays:
            "Previous 7 Days"
        case .previousThirtyDays:
            "Previous 30 Days"
        case .older:
            "Older"
        }
    }
}
