import SwiftUI
import UIKit
import PhotosUI
import AVKit

/// Where a tapped routine navigates to, and whether it should open straight
/// into the editor (used right after creating one).
private struct RoutineRoute: Identifiable, Hashable {
    let id: UUID
    let startInEdit: Bool
}

struct RoutinesView: View {
    @EnvironmentObject private var store: FolderStore
    @EnvironmentObject private var language: AppLanguage

    @State private var route: RoutineRoute?
    @State private var showingNew = false
    @State private var newName = ""

    private var s: Strings { language.s }

    var body: some View {
        Group {
            if store.routines.isEmpty {
                ContentUnavailableView {
                    Label(s.routines, systemImage: "folder")
                } description: {
                    Text(s.noRoutines)
                }
            } else {
                List {
                    ForEach(store.routines) { doc in
                        Button { route = RoutineRoute(id: doc.id, startInEdit: false) } label: {
                            RoutineRow(doc: doc)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        offsets.map { store.routines[$0] }.forEach(store.deleteRoutine)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newName = ""; showingNew = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(item: $route) { route in
            RoutineDetailView(id: route.id, startInEdit: route.startInEdit)
        }
        .alert(s.newRoutine, isPresented: $showingNew) {
            TextField(s.routineNamePrompt, text: $newName)
            Button(s.cancel, role: .cancel) { }
            Button(s.add) { createRoutine() }
        }
    }

    private func createRoutine() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let doc = RoutineDoc(id: UUID(), body: "# \(name)\n\n", updatedAt: .now,
                             sourceLanguage: language.current)
        store.saveRoutine(doc)
        route = RoutineRoute(id: doc.id, startInEdit: true)
    }
}

/// Read-only rendered view of a routine, with an Edit button. Looks the doc up
/// fresh from the store so it reflects the latest edits.
private struct RoutineDetailView: View {
    @EnvironmentObject private var store: FolderStore
    @EnvironmentObject private var language: AppLanguage

    let id: UUID
    let startInEdit: Bool

    @State private var showEditor = false
    @State private var didAutoOpen = false

    private var s: Strings { language.s }
    private var doc: RoutineDoc? { store.routines.first { $0.id == id } }

    private var detailTitle: String {
        guard let doc else { return s.untitled }
        let title = doc.resolvedTitle(for: language.current)
        return title.isEmpty ? s.untitled : title
    }

    var body: some View {
        Group {
            if let doc {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        MarkdownPreview(markdown: doc.resolvedBody(for: language.current))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let last = doc.edits.last {
                            Divider()
                            HStack(spacing: 6) {
                                Image(systemName: "pencil").font(.caption2)
                                Text(last.device).font(.caption)
                                Spacer()
                                Text(last.date, format: .dateTime.day().month().hour().minute()
                                    .locale(language.current.locale)).font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView(s.untitled, systemImage: "folder")
            }
        }
        .navigationTitle(detailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(s.editTab) { showEditor = true }.disabled(doc == nil)
            }
        }
        .sheet(isPresented: $showEditor) {
            if let doc {
                NavigationStack { RoutineEditorView(doc: doc, uiLanguage: language.current) }
            }
        }
        .onAppear {
            if startInEdit && !didAutoOpen { didAutoOpen = true; showEditor = true }
        }
    }
}

private struct RoutineRow: View {
    @EnvironmentObject private var language: AppLanguage
    let doc: RoutineDoc

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                let title = doc.resolvedTitle(for: language.current)
                Text(title.isEmpty ? language.s.untitled : title)
                Text(doc.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Editor

private struct RoutineEditorView: View {
    @EnvironmentObject private var store: FolderStore
    @EnvironmentObject private var language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var mode: Mode = .edit
    @StateObject private var controller = MarkdownEditingController()
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var showLink = false
    @State private var linkLabel = ""
    @State private var linkURLString = ""

    private let doc: RoutineDoc
    private let uiLanguage: Language
    private enum Mode { case edit, preview }

    init(doc: RoutineDoc, uiLanguage: Language) {
        self.doc = doc
        self.uiLanguage = uiLanguage
        _text = State(initialValue: doc.resolvedBody(for: uiLanguage))
    }

    private var s: Strings { language.s }

    private var currentTitle: String {
        let title = RoutineDoc(id: doc.id, body: text, updatedAt: .now).title
        return title.isEmpty ? s.untitled : title
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text(s.editTab).tag(Mode.edit)
                Text(s.previewTab).tag(Mode.preview)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            if mode == .edit {
                MarkdownEditor(text: $text, controller: controller)
                Divider()
                formatBar
            } else {
                ScrollView {
                    MarkdownPreview(markdown: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(s.cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(s.save) { save() }
            }
        }
        .onChange(of: photoItem) { _, item in handleMedia(item, fallbackExt: "jpg") { photoItem = nil } }
        .onChange(of: videoItem) { _, item in handleMedia(item, fallbackExt: "mov") { videoItem = nil } }
        .alert(s.insertLink, isPresented: $showLink) {
            TextField(s.linkText, text: $linkLabel)
            TextField(s.linkURL, text: $linkURLString)
            Button(s.cancel, role: .cancel) { resetLink() }
            Button(s.add) { insertLink() }
        }
    }

    private var formatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                barButton("bold", s.bold) { controller.wrapSelection("**", "**") }
                barButton("italic", s.italic) { controller.wrapSelection("*", "*") }
                barButton("strikethrough", s.strikethrough) { controller.wrapSelection("~~", "~~") }
                barButton("number", s.heading) { controller.prefixLine("## ") }
                barButton("list.bullet", s.bulletList) { controller.prefixLine("- ") }
                barButton("list.number", s.numberedList) { controller.prefixLine("1. ") }
                barButton("link", s.insertLink) { showLink = true }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo").font(.title3)
                }
                .accessibilityLabel(s.attachPhoto)
                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Image(systemName: "video").font(.title3)
                }
                .accessibilityLabel(s.attachVideo)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func barButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3) }
            .accessibilityLabel(label)
    }

    private func handleMedia(_ item: PhotosPickerItem?, fallbackExt: String, clear: @escaping () -> Void) {
        guard let item else { return }
        Task {
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? fallbackExt
            if let data = try? await item.loadTransferable(type: Data.self),
               let rel = store.saveMedia(data, ext: ext) {
                controller.insert("\n![](\(rel))\n")
            }
            clear()
        }
    }

    private func insertLink() {
        let label = linkLabel.isEmpty ? linkURLString : linkLabel
        controller.insert("[\(label)](\(linkURLString))")
        resetLink()
    }

    private func resetLink() { linkLabel = ""; linkURLString = "" }

    private func save() {
        var updated = doc
        // Editing what you see re-authors the doc in your language and clears
        // now-stale translations (the offline process regenerates them).
        if text != doc.resolvedBody(for: uiLanguage) {
            updated.body = text
            updated.sourceLanguage = uiLanguage
            updated.translations = [:]
        }
        updated.updatedAt = .now
        store.saveRoutine(updated)
        dismiss()
    }
}

// MARK: - Markdown text view (selection-aware formatting)

@MainActor
final class MarkdownEditingController: ObservableObject {
    weak var textView: UITextView?

    /// Wrap the current selection (or insert empty markers at the caret).
    func wrapSelection(_ left: String, _ right: String) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let range = tv.selectedRange
        let selected = ns.substring(with: range)
        let replacement = left + selected + right
        tv.text = ns.replacingCharacters(in: range, with: replacement)
        let caret = selected.isEmpty
            ? range.location + (left as NSString).length
            : range.location + (replacement as NSString).length
        tv.selectedRange = NSRange(location: caret, length: 0)
        notify(tv)
    }

    /// Insert a prefix at the start of the caret's line (headings, lists).
    func prefixLine(_ prefix: String) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: tv.selectedRange.location, length: 0))
        tv.text = ns.replacingCharacters(in: NSRange(location: lineRange.location, length: 0), with: prefix)
        tv.selectedRange = NSRange(location: tv.selectedRange.location + (prefix as NSString).length, length: 0)
        notify(tv)
    }

    /// Insert text at the caret (media, links).
    func insert(_ string: String) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let range = tv.selectedRange
        tv.text = ns.replacingCharacters(in: range, with: string)
        tv.selectedRange = NSRange(location: range.location + (string as NSString).length, length: 0)
        notify(tv)
    }

    private func notify(_ tv: UITextView) {
        tv.delegate?.textViewDidChange?(tv)
    }
}

private struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditingController

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.autocapitalizationType = .sentences
        tv.text = text
        controller.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        controller.textView = tv
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ tv: UITextView) { text.wrappedValue = tv.text }
    }
}

// MARK: - Markdown preview

private struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parseBlocks(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .paragraph(let text):
            inline(text)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•"); inline(text)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").monospacedDigit(); inline(text)
            }
        case .media(let path):
            MediaView(path: path)
        case .spacer:
            Color.clear.frame(height: 2)
        }
    }

    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }
}

private enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String)
    case numbered(Int, String)
    case media(String)
    case spacer
}

private func parseBlocks(_ md: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    for raw in md.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { blocks.append(.spacer); continue }
        if let path = imagePath(line) { blocks.append(.media(path)); continue }
        if line.hasPrefix("#") {
            let hashes = line.prefix { $0 == "#" }.count
            let text = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            blocks.append(.heading(min(hashes, 3), text)); continue
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            blocks.append(.bullet(String(line.dropFirst(2)))); continue
        }
        if let r = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            let number = Int(line.prefix { $0.isNumber }) ?? 1
            blocks.append(.numbered(number, String(line[r.upperBound...]))); continue
        }
        blocks.append(.paragraph(line))
    }
    return blocks
}

/// Returns the path inside `![alt](path)` when the whole line is just an image.
private func imagePath(_ line: String) -> String? {
    guard line.range(of: #"^!\[[^\]]*\]\([^)]+\)$"#, options: .regularExpression) != nil,
          let open = line.lastIndex(of: "("),
          let close = line.lastIndex(of: ")"),
          open < close else { return nil }
    return String(line[line.index(after: open)..<close])
}

private struct MediaView: View {
    @EnvironmentObject private var store: FolderStore
    let path: String

    @State private var image: UIImage?
    @State private var videoURL: URL?

    private var isVideo: Bool {
        ["mov", "mp4", "m4v"].contains((path as NSString).pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if isVideo, let videoURL {
                VideoPlayer(player: AVPlayer(url: videoURL))
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    .frame(height: 120)
                    .overlay { ProgressView() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard image == nil, videoURL == nil, let data = store.mediaData(path) else { return }
        if isVideo {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent((path as NSString).lastPathComponent)
            try? data.write(to: tmp)
            videoURL = tmp
        } else {
            image = UIImage(data: data)
        }
    }
}
