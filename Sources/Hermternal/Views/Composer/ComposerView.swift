import HermternalCore
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The message composer.
///
/// The accessory row includes one Format disclosure control.
/// Explicit Format activation reveals actions above the message field.
/// Row three appears only while the draft holds attachments.
///
/// Every row sits inside one glass panel. That panel is the only surface
/// the composer paints, and it is inset from the detail column edge, so it
/// never meets the split divider. The safe area around it stays transparent.
/// The transcript shows through above and below the panel, and nothing may
/// add a full width band here or at the mount.
struct ComposerView: View {
    @Bindable var model: ComposerModel
    /// Incremented by the caller to put the caret in the message field. The
    /// composer reacts to a change of this value, so it never takes first
    /// responder on its own during a launch or a chat switch.
    var focusRequest: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hermternalAccentColor) private var accentColor

    /// Token for this view instance. Pass it to unmount so a late disappear is a no-op.
    @State private var mountToken: ComposerMountToken?
    @State private var handledFocusRequest = 0
    @State private var isFileImporterPresented = false
    @State private var filePickerTarget: ComposerRouteToken?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var photoPickerTarget: ComposerRouteToken?
    @State private var quickLookURL: URL?
    @State private var formatRequest: ComposerEditorFormat?
    @State private var isFormattingExpanded = false
    @State private var localFocusRequest = 0
    @State private var isEditorFocused = false

    var body: some View {
        composerLayout
        // Escape belongs to the composer only while it has something to
        // cancel. The caller owns the find bar and receives the key press
        // when the composer does not use it.
        .onKeyPress(.escape) { model.handleEscape() ? .handled : .ignored }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.18),
            value: model.attachments.count + model.outgoing.count
        )
        .quickLookPreview($quickLookURL)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            let target = filePickerTarget
            filePickerTarget = nil
            switch result {
            case let .success(urls):
                guard let target else { return }
                model.attach(urls.map { ComposerAttachmentSource.picked($0) }, target: target)
            case .failure:
                model.reportSelectionFailure()
            }
        }
        .onChange(of: photoSelection) { _, items in
            handlePhotoSelectionChange(items)
        }
        .onChange(of: isEditorFocused) { _, focused in
            if ComposerEditorInteractionPolicy.shouldHideFormattingRow(
                isEditorFocused: focused,
                hasSource: !model.text.isEmpty
            ) {
                isFormattingExpanded = false
            }
        }
        .onChange(of: model.text) { _, text in
            if text.isEmpty {
                isFormattingExpanded = false
            }
        }
        .onChange(of: focusRequest) { _, request in
            guard request != handledFocusRequest else { return }
            handledFocusRequest = request
        }
        .onAppear {
            // Issue a mount token for this view. An unmount without it is a no-op.
            // Defended by outOfOrderUnmountDoesNotBlockSubmit.
            mountToken = model.mount()
        }
        .onDisappear {
            // SwiftUI can fire this after the successor appears. Pass the token.
            if let mountToken {
                model.unmount(mountToken)
            }
            mountToken = nil
        }
        // A refused or failed action states its reason once. The composer has
        // no room for a fourth row, and an alert is the system answer.
        .alert(
            "Composer",
            isPresented: noticeIsPresented
        ) {
            Button("OK", role: .cancel) { model.dismissNotice() }
        } message: {
            Text(noticeMessage)
        }
    }

    /// The glass panel, and the insets that keep it clear of the split
    /// divider, the window edge, and the transcript above.
    ///
    /// The composer is mounted as a bottom safe area inset, so its own height
    /// is the space the transcript gives up. Every row therefore states a
    /// finite height: the field stops growing at eight lines, and the
    /// attachment row takes the height of one chip.
    private var composerLayout: some View {
        // The surface takes its radius from the toast card, which fills the
        // same role: an app-owned card that floats over the transcript, holds
        // more than one row, and pads 11pt vertically. The toast states a 44pt
        // minimum height, and the composer's two rows land in the same height
        // class, so the two cards read as one family. `AppShapeScale.toast` is
        // that radius. The transcript user bubble draws at the same token, so
        // the composer now agrees with the surface directly above it.
        //
        // The one-row surfaces are deliberately not the authority here. The
        // find bar and the search field are both capsules, and a capsule reads
        // as too round once the composer is more than one row tall. The search
        // panel is not the authority either: it is a modal card that reaches a
        // third of the window height.
        //
        // The system concentric shapes do not apply in this host. This view is
        // hosted from AppKit through `NSHostingController<MainSplitRoot>`, and
        // the app declares no `containerShape`. `ContainerRelativeShape` then
        // resolves to a plain rectangle, and concentric corners resolve to
        // square ones unless a `minimum:` radius is supplied, which would be a
        // guessed number. `WindowBackdrop` records the same limit for the
        // window glass.
        //
        // One glass shape, and therefore no `GlassEffectContainer`. A
        // container exists to union and morph glass effects that sit near each
        // other; the union of a single shape is that shape, so `spacing: 14`
        // had nothing to merge and the container was a second geometry to
        // resolve for no change to the picture.
        //
        // Removing it also removes a place a stale panel width could come
        // from, and this composer is laid out at more than one width: measured
        // on macOS 26.6.2 in a 1040pt window, one pass applies the rows their
        // ideal 196.5pt and a later pass applies the 714pt they occupy. A
        // panel drawn at the first of those is a box the trailing controls sit
        // outside of, which is the reported defect. The panel is drawn by the
        // compositor rather than by a layer this process can read, so that
        // last step is reasoning rather than a measurement.
        let shape = RoundedRectangle(
            cornerRadius: AppShapeScale.toast,
            style: .continuous
        )
        return rows
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassEffect(.regular.interactive(), in: shape)
            .tint(accentColor)
            // 18pt matches the find bar and the transcript gutter. It is also
            // what holds the panel off the split divider on the leading side,
            // and off the window edge on the trailing side.
            .padding(.horizontal, 18)
            // Outside the panel, and therefore transparent: this is the space
            // the safe area inset reserves, and nothing paints in it.
            .padding(.top, 10)
            .padding(.bottom, 16)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            messageRow
            controlRow
            if !model.attachments.isEmpty || !model.outgoing.isEmpty {
                ComposerAttachmentStrip(
                    attachments: model.attachments,
                    outgoing: model.outgoing,
                    progress: model.stagingProgress,
                    isEnabled: !model.route.isReadOnly,
                    onQuickLook: { quickLookURL = $0 },
                    onRemove: { model.removeAttachment($0) }
                )
            }
        }
        // Measured inside the panel, so the density breakpoints read the
        // width the controls actually have rather than the width of the
        // column that carries them.
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.width
        } action: { width in
            // A zero width is not a narrow composer. The composer is a bottom
            // safe-area inset, and a layout pass applies a no-size geometry to
            // this subtree while it resolves how much room to reserve —
            // observed on macOS 26.6.2 as one 0x0 pass per cycle. Reporting it
            // would drop the whole control row to its narrowest arrangement
            // and back on every pass, which is two rebuilds of the row for a
            // width the composer never draws at.
            guard width > 0 else { return }
            model.updateWidth(width)
        }
    }
    private var noticeMessage: String {
        model.notice?.message ?? ""
    }

    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { model.notice != nil },
            set: { isPresented in
                if !isPresented {
                    model.dismissNotice()
                }
            }
        )
    }


    // MARK: - Row one
    private var messageRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if ComposerEditorInteractionPolicy.formattingRowIsVisible(
                isEditorFocused: isEditorFocused,
                isExpanded: isFormattingExpanded,
                hasSource: !model.text.isEmpty
            ) {
                ComposerFormattingRow(
                    mode: model.editorMode,
                    onFormat: {
                        formatRequest = $0
                        isFormattingExpanded = ComposerEditorInteractionPolicy
                            .formattingActionPreservesFocus(isEditorFocused)
                    },
                    onToggleSource: {
                        let next: ComposerEditorMode = model.editorMode == .source ? .wysiwyg : .source
                        _ = model.setEditorMode(next)
                    }
                )
                .disabled(model.route.isReadOnly)
                .transition(
                    reduceMotion
                        ? .identity
                        : .opacity.combined(with: .move(edge: .top))
                )
            }
            HStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    ComposerMarkdownEditor(
                        source: $model.text,
                        mode: Binding(
                            get: { model.editorMode },
                            set: { _ = model.setEditorMode($0) }
                        ),
                        isFocused: $isEditorFocused,
                        isEditable: !model.route.isReadOnly,
                        focusRequest: focusRequest + localFocusRequest,
                        formatRequest: formatRequest,
                        onSubmit: { model.submit() },
                        onEscape: { model.handleEscape() },
                        onFormatHandled: { formatRequest = nil }
                    )
                    // The placeholder is always in the tree, and always the
                    // same size, so the first character removes no view and
                    // moves no line. The field states the prompt as its own
                    // accessibility hint below, so this copy is decoration.
                    Text("Message Hermes…")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                        .padding(.top, 7)
                        .opacity(model.text.isEmpty ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Message")
                .accessibilityHint(model.text.isEmpty ? "Message Hermes…" : "")
            }
            if let error = model.editorError {
                Text("Source error: \(error.message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Source error: \(error.message)")
            }
        }
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(
                    duration: ComposerEditorInteractionPolicy.formattingRowTransitionDuration
                ),
            value: isEditorFocused
        )
    }

    // MARK: - Row two

    private var controlRow: some View {
        HStack(spacing: 8) {
            formatDisclosureButton
            filesButton
            photosButton
            recordButton
            if model.density != .minimal {
                ComposerStatusLabel(model: model)
            }
            Spacer(minLength: 8)
            ComposerModelMenu(model: model)
            ComposerReasoningMenu(model: model)
            dictateButton
            primaryButton
        }
        .controlSize(model.density == .full ? .large : .regular)
    }

    /// The left controls stay icon only while the row is narrow, because a
    /// revealed title there would push the row past the detail width.
    private var canRevealLabels: Bool { model.density != .minimal }

    private var formatDisclosureButton: some View {
        Button {
            guard !model.text.isEmpty else { return }
            isFormattingExpanded = true
            if !isEditorFocused {
                localFocusRequest += 1
            }
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .disabled(model.route.isReadOnly || model.text.isEmpty)
        .help("Show formatting actions.")
        .accessibilityLabel("Format")
        .accessibilityValue(isFormattingExpanded ? "Shown" : "Hidden")
        .accessibilityIdentifier("composer-format-disclosure")
    }

    private var filesButton: some View {
        ComposerHoverReveal { isRevealed in
            Button {
                filePickerTarget = model.route.token
                isFileImporterPresented = true
            } label: {
                Label("Files", systemImage: "paperclip")
            }
            .buttonStyle(.borderless)
            .labelStyle(
                ComposerRevealLabelStyle(showsTitle: canRevealLabels && isRevealed)
            )
            .disabled(!model.canAttach)
            .help(attachHelp)
            .accessibilityLabel("Files")
        }
    }

    private var photosButton: some View {
        ComposerHoverReveal { isRevealed in
            PhotosPicker(
                selection: $photoSelection,
                maxSelectionCount: max(1, model.attachmentSlotsLeft),
                matching: .images,
                preferredItemEncoding: .current
            ) {
                Label("Photos", systemImage: "photo")
            }
            .buttonStyle(.borderless)
            .labelStyle(
                ComposerRevealLabelStyle(showsTitle: canRevealLabels && isRevealed)
            )
            .disabled(!model.canAttach)
            .help(attachHelp)
            .accessibilityLabel("Photos")
            .simultaneousGesture(
                TapGesture().onEnded {
                    photoPickerTarget = model.route.token
                }
            )
        }
    }

    private var recordButton: some View {
        ComposerHoverReveal { isRevealed in
            Button {
                model.toggleRecording()
            } label: {
                Label(recordTitle, systemImage: recordSymbol)
            }
            .buttonStyle(.borderless)
            .labelStyle(
                ComposerRevealLabelStyle(showsTitle: canRevealLabels && isRevealed)
            )
            .tint(model.recordingStatus == .recording ? .red : accentColor)
            .disabled(!model.canRecord)
            .help(recordHelp)
            .accessibilityLabel(recordTitle)
        }
    }

    private var dictateButton: some View {
        Button {
            model.toggleDictation()
        } label: {
            Label(dictateTitle, systemImage: dictateSymbol)
        }
        .buttonStyle(.borderless)
        .labelStyle(ComposerRevealLabelStyle(showsTitle: false))
        .tint(model.dictationStatus == .listening ? .red : accentColor)
        .disabled(!model.canDictate)
        .help(dictateHelp)
        .accessibilityLabel(dictateTitle)
    }

    private var primaryButton: some View {
        Button {
            switch model.primaryAction {
            case .stop:
                model.stop()
            case .send:
                model.submit()
            }
        } label: {
            primaryLabel
        }
        .buttonStyle(.borderedProminent)
        .disabled(isPrimaryDisabled)
        .help(primaryHelp)
        .accessibilityLabel(isStopping ? "Stop" : "Send")
    }

    @ViewBuilder private var primaryLabel: some View {
        if model.isSubmitting || model.stagingProgress != nil {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: isStopping ? "stop.fill" : "arrow.up")
                .font(ComposerIconMetrics.action)
        }
    }

    // MARK: - Control state

    private var isStopping: Bool { model.primaryAction == .stop }

    private var isPrimaryDisabled: Bool {
        if case let .send(isEnabled) = model.primaryAction { return !isEnabled }
        return false
    }

    private var primaryHelp: String {
        if isStopping { return "Stop the reply." }
        return model.sendDisabledReason ?? "Send the message."
    }

    private var attachHelp: String {
        if model.route.isReadOnly { return "This transcript is read only." }
        if model.attachmentSlotsLeft == 0 {
            return "The composer accepts at most \(ComposerAttachmentLimits.maximumItems) attachments."
        }
        return "Attach a file to this message."
    }

    private var recordTitle: String {
        model.recordingStatus == .recording ? "Stop Recording" : "Record Audio"
    }

    private var recordSymbol: String {
        model.recordingStatus == .recording ? "stop.fill" : "waveform"
    }

    private var recordHelp: String {
        switch model.recordingStatus {
        case .idle:
            if model.dictationStatus == .listening {
                return "Dictation uses the microphone now."
            }
            if model.attachmentSlotsLeft == 0 {
                return "The composer accepts at most \(ComposerAttachmentLimits.maximumItems) attachments."
            }
            return "Record audio and attach it."
        case .requestingPermission:
            return "Waiting for microphone permission."
        case .recording:
            return "Stop the recording and attach it."
        case .finishing:
            return "Saving the recording."
        case let .unavailable(reason):
            return reason
        }
    }

    private var dictateTitle: String {
        model.dictationStatus == .listening ? "Stop Dictation" : "Dictate"
    }

    private var dictateSymbol: String {
        model.dictationStatus == .listening ? "mic.fill" : "mic"
    }

    private var dictateHelp: String {
        switch model.dictationStatus {
        case .idle:
            if model.recordingStatus == .recording {
                return "The recorder uses the microphone now."
            }
            return "Dictate the message."
        case .preparing:
            return "Preparing dictation."
        case let .installingModel(locale):
            return "Installing the speech model for \(locale)."
        case .listening:
            return "Stop dictation."
        case let .unavailable(reason):
            return reason
        }
    }

    // MARK: - Photos
    private func handlePhotoSelectionChange(_ items: [PhotosPickerItem]) {
        let target = photoPickerTarget
        photoPickerTarget = nil
        importPhotos(items, target: target)
    }


    private func importPhotos(_ items: [PhotosPickerItem], target: ComposerRouteToken?) {
        guard !items.isEmpty else { return }
        photoSelection = []
        guard let target else {
            model.reportSelectionFailure()
            return
        }
        Task {
            var sources: [ComposerAttachmentSource] = []
            sources.reserveCapacity(items.count)
            for item in items {
                do {
                    guard let file = try await item.loadTransferable(
                        type: ComposerPhotoFile.self
                    ) else {
                        model.reportSelectionFailure(target: target)
                        continue
                    }
                    sources.append(.temporary(file.url))
                } catch {
                    model.reportSelectionFailure(target: target)
                }
            }
            model.attach(sources, target: target)
        }
    }
}

/// One line that names composer work in flight.
///
/// The line is absent while nothing runs, so the composer shows no indicator
/// that cannot finish.
private struct ComposerStatusLabel: View {
    let model: ComposerModel

    var body: some View {
        if let description = model.statusDescription {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The one size the composer draws its action glyphs at.
///
/// The controls in the control row are icon first: three of them show a
/// title only while the pointer is over them, and two never show one. The
/// glyph therefore carries the whole control, and at the ambient `.body`
/// size it reads smaller than every other glyph the app owns: the sidebar
/// account row draws at `.title3`, and the search field glyph at 15pt.
///
/// Two steps of the macOS type scale, and no third. `action` is one control
/// in the control row. `chip` is the kind glyph of an attachment, which sits
/// beside `.callout` text in a denser row, so it takes the size of the
/// sidebar row glyph instead and stays one step below the row above it.
///
/// One weight throughout, so no control reads bolder than its neighbour.
/// The prominent Send button takes its emphasis from its fill rather than
/// from a heavier stroke.
///
/// Only the glyph is stated here. Titles keep the ambient font, so a reveal
/// adds the width it always did.
enum ComposerIconMetrics {
    /// One control in the composer control row: 15pt.
    static let action = Font.title3.weight(.medium)

    /// The kind glyph of an attachment chip: 13pt.
    static let chip = Font.body.weight(.medium)
}

/// Shows or hides the title of a system label, without changing the icon or
/// the accessibility label.
struct ComposerLabelStyle: LabelStyle {
    let showsTitle: Bool

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            Label(configuration).labelStyle(.titleAndIcon)
        } else {
            Label(configuration).labelStyle(.iconOnly)
        }
    }
}

/// Gives one control a pointer driven reveal.
///
/// The wrapper owns the pointer state, the timing, and the reduced motion
/// rule, so every composer control that grows a label grows the same way.
/// Only the control under the pointer animates, because each wrapper holds
/// its own state. The closure receives true while the pointer is over it.
///
/// The spring has no overshoot and retargets from wherever the reveal is
/// when the pointer leaves, so a fast pass over the row cannot queue frames.
/// Reduced motion drops the animation, and the label appears at once.
struct ComposerHoverReveal<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isHovered)
    }
}

/// Shows an icon, and puts the title beside it while the control is revealed.
///
/// One stack holds both parts, so the control keeps its identity and its
/// width animates. The title states a fixed size, so a reveal adds a known
/// amount of width and never proposes an unbounded one. The call site states
/// the accessibility label, because the title is not always in the tree.
///
/// The style also states the glyph size, so every control that uses it
/// draws its icon at the one composer action metric, while its title keeps
/// the ambient font.
struct ComposerRevealLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(ComposerIconMetrics.action)
            if showsTitle {
                configuration.title
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
    }
}

/// A photo copied out of the photo library as a file.
///
/// A file representation keeps the picked bytes, so the composer never holds
/// image data and never re-encodes an image. The composer moves this file
/// into the draft directory of the chat.
struct ComposerPhotoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            // The system deletes its own file after this closure returns, so
            // the copy happens here. One folder per import keeps the original
            // file name, which the attachment chip shows.
            let manager = FileManager.default
            let folder = manager.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: received.file.lastPathComponent)
            try manager.copyItem(at: received.file, to: destination)
            return ComposerPhotoFile(url: destination)
        }
    }
}
