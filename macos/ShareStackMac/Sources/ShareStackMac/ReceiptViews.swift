import SwiftUI
import AppKit

struct HiddenFocusRing: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

enum StackDesign {
    static let accent = Color.teal
    static let card = Color.primary.opacity(0.045)

    static func fileSymbol(_ mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo.fill" }
        if mimeType.hasPrefix("video/") { return "film.fill" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType == "application/pdf" { return "doc.richtext.fill" }
        if mimeType.hasPrefix("text/") { return "text.alignleft" }
        return "doc.fill"
    }
}

struct StackBrandMark: View {
    var body: some View {
        Image(systemName: "square.stack.3d.up.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ReceiptSettingsView: View {
    @ObservedObject var model: MacAppModel
    @AppStorage("arrivalShowLibrary") private var arrivalShowLibrary = true
    @AppStorage("arrivalSound") private var arrivalSound = true

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("보관함 열기", isOn: $arrivalShowLibrary)
                Toggle("도착 알림음", isOn: $arrivalSound)
            }
            Picker("수신 방식", selection: Binding(
                get: { model.receiptSettings.mode },
                set: { model.setReceiptMode($0) }
            )) {
                Text("보관함에서 확인").tag(ReceiptSettings.Mode.inbox)
                Text("자동 저장").tag(ReceiptSettings.Mode.automatic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isReceiving)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("저장 폴더", systemImage: "folder.fill").font(.headline)
                Spacer()
                Button("변경…") { model.chooseReceiptFolder() }
                    .disabled(model.isReceiving)
            }
            Text(model.receiptSettings.folderPath)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(2)
                .help(model.receiptSettings.folderPath)
            }
            .padding(8)
            .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("임시 보관 폴더", systemImage: "tray.fill").font(.headline)
                    Spacer()
                    Button("변경…") { model.chooseInboxFolder() }
                        .disabled(model.isReceiving)
                }
                Text(model.receiptSettings.inboxFolderPath ?? "앱 기본 폴더")
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .help(model.receiptSettings.inboxFolderPath ?? "앱 기본 폴더")
                Text("보관함 파일의 위치입니다. 보관함에서 삭제하면 실제 파일도 삭제됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 14))
            WorkspaceRegistrationView()
            Toggle("AI 읽기 사용", isOn: Binding(
                get: { model.aiExchangeEnabled },
                set: { model.setAIExchangeEnabled($0) }
            ))
                .disabled(model.isReceiving)
            Spacer(minLength: 0)
            Text(model.receiptMessage)
                .font(.caption)
                .lineLimit(1)
                .help(model.receiptMessage)
                .accessibilityLabel("처리 상태: \(model.receiptMessage)")
        }
        }
        .modifier(HiddenFocusRing())
        .tint(StackDesign.accent)
    }
}

struct ReceiptInboxView: View {
    @ObservedObject var model: MacAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var selectedIDs = Set<String>()
    private let itemsPerPage = 6

    private var pageCount: Int { max(1, (model.libraryItems.count + itemsPerPage - 1) / itemsPerPage) }
    private var currentPage: Int { min(page, pageCount - 1) }
    private var visibleItems: [LibraryItem] {
        Array(model.libraryItems.dropFirst(currentPage * itemsPerPage).prefix(itemsPerPage))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("보관함").font(.system(size: 16, weight: .semibold))
                Text("\(model.libraryItems.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(StackDesign.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(StackDesign.accent.opacity(0.12), in: Capsule())
                Spacer()
                if model.isReceiving { ProgressView().controlSize(.small) }
                Button("선택 기기전송") {
                    model.sendSelectedToGalaxy(selectedIDs)
                }
                .controlSize(.small)
                .disabled(selectedIDs.isEmpty || model.isReceiving || model.certificateFingerprint.isEmpty)
                Button { model.receiveAllInboxItems() } label: {
                    Label("전체 수신", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(model.inboxItems.isEmpty || model.isReceiving)
            }
            Text("체크한 파일만 AI가 읽을 수 있습니다.")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !model.aiExchangeEnabled {
                Label("설정에서 AI 읽기가 중지되어 있습니다.", systemImage: "pause.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.libraryItems.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 30, weight: .light))
                        .foregroundStyle(StackDesign.accent)
                    Text("보관 중인 파일 없음").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(visibleItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Toggle("전송 선택", isOn: Binding(
                                        get: { selectedIDs.contains(item.id) },
                                        set: { selected in
                                            if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
                                        }
                                    ))
                                    .labelsHidden().toggleStyle(.checkbox)
                                    .accessibilityLabel("\(item.name) 기기 전송 선택")
                                    Toggle("AI 허용", isOn: Binding(
                                        get: { model.aiReadChecked(item) },
                                        set: { requested in
                                            model.setAIReadAllowed(model.aiReadProgress[item.id] == nil ? requested : false, for: item)
                                        }
                                    ))
                                    .toggleStyle(.checkbox).font(.system(size: 11))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .accessibilityLabel("\(item.name) AI 읽기 허용")
                                    .accessibilityValue(model.aiReadProgress[item.id].map {
                                        "AI 공개 준비 \(Int($0 * 100))퍼센트"
                                    } ?? (model.aiReadChecked(item) ? "허용됨" : "해제됨"))
                                    .help(model.aiReadProgress[item.id] == nil ? "AI 허용" : "AI 공개 준비 중 · 다시 누르면 취소")
                                    Image(systemName: StackDesign.fileSymbol(item.mimeType))
                                        .foregroundStyle(StackDesign.accent).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.system(size: 12, weight: .medium))
                                            .lineLimit(1).help(item.name)
                                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if let transfer = item.transfer {
                                        if let error = transfer.saveError {
                                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                                .help(error).accessibilityLabel("자동 저장 실패: \(error)")
                                        }
                                        if transfer.state == "saved" {
                                            Text("저장됨").font(.caption2).foregroundStyle(.secondary)
                                            Button(role: .destructive) { model.cancelInboxItem(transfer) } label: {
                                                Image(systemName: "trash").frame(width: 22, height: 24)
                                            }
                                            .buttonStyle(.plain).disabled(model.isReceiving)
                                            .help("보관함에서 제거 (저장된 파일 유지)")
                                            .accessibilityLabel("\(item.name) 보관함에서 제거, 저장된 파일 유지")
                                        } else {
                                            Button("수신") { model.receiveInboxItem(transfer) }
                                                .buttonStyle(.bordered).controlSize(.small)
                                                .disabled(model.isReceiving)
                                                .accessibilityLabel("\(item.name) 수신")
                                            Button(role: .destructive) { model.cancelInboxItem(transfer) } label: {
                                                Image(systemName: "xmark").frame(width: 22, height: 24)
                                            }
                                            .buttonStyle(.plain).disabled(model.isReceiving)
                                            .help("임시 보관 파일 삭제")
                                            .accessibilityLabel("\(item.name) 취소 및 임시 파일 삭제")
                                        }
                                    } else if let file = item.exchange {
                                        Button(role: .destructive) { model.deleteAIExchangeItem(file) } label: {
                                            Image(systemName: "trash").frame(width: 22, height: 24)
                                        }
                                        .buttonStyle(.plain).disabled(model.isReceiving)
                                        .accessibilityLabel("\(item.name) 보관 파일 삭제")
                                    }
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(alignment: .leading) {
                                GeometryReader { geometry in
                                    if let progress = model.aiReadProgress[item.id] {
                                        Rectangle().fill(StackDesign.accent.opacity(0.14))
                                            .frame(width: geometry.size.width * CGFloat(min(1, max(0, progress))))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                            .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                Spacer(minLength: 0)
                if pageCount > 1 {
                    HStack {
                        Button("이전") { page = currentPage - 1 }.disabled(currentPage == 0)
                        Spacer()
                        Text("\(currentPage + 1) / \(pageCount)").font(.caption).monospacedDigit()
                        Spacer()
                        Button("다음") { page = currentPage + 1 }.disabled(currentPage + 1 >= pageCount)
                    }.buttonStyle(.borderless).controlSize(.small)
                }
            }
            if !model.receiptMessage.isEmpty {
                Text(model.receiptMessage).font(.caption).lineLimit(2).help(model.receiptMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("처리 상태: \(model.receiptMessage)")
            }
        }
        .transaction { if reduceMotion { $0.animation = nil } }
        .tint(StackDesign.accent)
        .onAppear { model.refresh() }
        .onChange(of: model.libraryItems) { items in
            page = currentPage
            selectedIDs.formIntersection(Set(items.map(\.id)))
        }
    }
}


private struct WorkspaceRegistrationView: View {
    @State private var records: [WorkspaceRecord] = []
    @State private var sessions: [WorkspaceStore.Session] = []
    @State private var selectedSession = ""
    @State private var busy = false
    @State private var message = ""

    private func store() throws -> WorkspaceStore {
        try WorkspaceStore(root: GUIBridge.directory().appendingPathComponent("Workspaces", isDirectory: true))
    }

    private func refresh() {
        do { let storage = try store(); records = try storage.list(); sessions = storage.sessions() }
        catch { message = "작업공간을 읽을 수 없습니다" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("폴더 작업공간", systemImage: "folder")
                Spacer()
                Button("폴더 추가…") { chooseFolder() }.disabled(busy)
            }
            Text("새 폴더는 비공개입니다. AI에서 작업공간 목록을 조회한 뒤 여기서 연결과 모드를 승인하세요.")
                .font(.caption2).foregroundStyle(.secondary)
            Picker("승인할 AI 연결", selection: $selectedSession) {
                Text("연결 선택").tag("")
                ForEach(sessions, id: \.id) { session in
                    Text(session.label + " · " + String(session.id.prefix(8))).tag(session.id)
                }
            }.font(.caption)
            Button("선택 연결 승인 취소") {
                try? store().revokeSession(selectedSession); selectedSession = ""; refresh()
            }.font(.caption).disabled(selectedSession.isEmpty)
            Text("연결 이름은 클라이언트가 제공한 이름입니다. 요청 직후 나타난 연결을 확인하세요. 앱 재시작 후 연결 승인은 다시 필요합니다.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(records, id: \.id) { record in
                VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.name).lineLimit(1)
                    Spacer()
                    Button("삭제") {
                        let alert = NSAlert()
                        alert.messageText = "작업공간 복사본을 삭제할까요?"
                        alert.informativeText = "원본 폴더는 유지됩니다."
                        alert.addButton(withTitle: "삭제")
                        alert.addButton(withTitle: "취소")
                        if alert.runModal() == .alertFirstButtonReturn {
                            do { try store().delete(record.id); refresh() }
                            catch { message = "삭제 실패" }
                        }
                    }.disabled(busy)
                }.font(.caption)
                Picker("접근 모드", selection: Binding(get: { record.mode }, set: { setMode(record, $0) })) {
                    Text("비공개").tag(WorkspaceRecord.Mode.privateMode)
                    Text("읽기 전용 / 분석").tag(WorkspaceRecord.Mode.readOnly)
                    Text("격리 복사본 편집").tag(WorkspaceRecord.Mode.edit)
                }.font(.caption)
                if let bound = try? store().boundSession(record.id), let session = sessions.first(where: { $0.id == bound }) {
                    Text("승인 연결: " + session.label + " · " + String(bound.prefix(8))).font(.caption2)
                } else if record.mode != .privateMode {
                    Text("승인된 연결 없음 · 연결을 선택하고 모드를 다시 승인하세요").font(.caption2).foregroundStyle(.secondary)
                    Button("선택 연결 승인") { setMode(record, record.mode) }.disabled(selectedSession.isEmpty)
                }
                Button("변경 내용 확인") { showChanges(record) }.font(.caption).disabled(record.mode == .privateMode)
                }.padding(.vertical, 4)
            }
            Text("비공개 전환과 삭제는 이후 접근을 차단합니다. 이미 AI에 전달한 내용은 회수되지 않습니다. 원본 반영은 지원하지 않습니다.")
                .font(.caption2).foregroundStyle(.secondary)
            if busy { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).font(.caption2) }
        }
        .padding(8).background(StackDesign.card, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in if !busy { refresh() } }
    }

    private func setMode(_ record: WorkspaceRecord, _ mode: WorkspaceRecord.Mode) {
        if mode != .privateMode && selectedSession.isEmpty { message = "먼저 승인할 AI 연결을 선택하세요"; return }
        let alert = NSAlert()
        alert.messageText = mode == .privateMode ? "작업공간을 비공개로 전환할까요?" : "선택한 AI 연결에 접근을 허용할까요?"
        alert.informativeText = mode == .edit ? "AI가 앱 관리 복사본을 수정하거나 새 텍스트 파일을 만들 수 있습니다. 원본은 변경하지 않습니다." : "읽기 전용에서는 파일 탐색과 내용 읽기만 가능합니다. 이미 전달한 내용은 회수할 수 없습니다."
        alert.addButton(withTitle: "적용"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store().setMode(record.id, mode, sessionID: mode == .privateMode ? nil : selectedSession); refresh(); message = "접근 모드 적용 완료" }
        catch { message = "접근 모드 적용 실패"; refresh() }
    }

    private func showChanges(_ record: WorkspaceRecord) {
        do {
            let changes = try store().guiChanges(record.id)
            let text = changes.items.isEmpty ? "변경사항 없음" : changes.items.map { $0.diff }.joined(separator: "\n") + (changes.nextCursor == nil ? "" : "\n[미리보기 일부입니다. MCP 변경사항 조회의 nextCursor로 이어서 확인하세요.]")
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
            view.string = text; view.isEditable = false; view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            let scroll = NSScrollView(frame: view.frame); scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            let alert = NSAlert(); alert.messageText = record.name + " · 복사본 변경사항"; alert.accessoryView = scroll; alert.addButton(withTitle: "닫기"); alert.runModal()
        } catch { message = "변경사항을 읽을 수 없습니다. AI 연결 승인을 확인하세요." }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        busy = true; message = "폴더 확인 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            let preview = Result { try store().preview(source) }
            DispatchQueue.main.async {
                guard case .success(let summary) = preview else { busy = false; message = "폴더 확인 실패 또는 크기 제한 초과"; return }
                let alert = NSAlert()
                alert.messageText = "폴더 복사본을 만들까요?"
                alert.informativeText = "포함 파일 \(summary.included)개 · 제외 항목 \(summary.excluded)개 · \(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))\n숨김 파일, 비밀 키, 빌드 산출물 및 링크를 제외합니다. 원본은 변경하지 않습니다."
                alert.addButton(withTitle: "복사"); alert.addButton(withTitle: "취소")
                guard alert.runModal() == .alertFirstButtonReturn else { busy = false; message = ""; return }
                message = "복사 중…"
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try store().importFolder(source) }
                    DispatchQueue.main.async {
                        busy = false
                        switch result {
                        case .success: message = "비공개 복사 완료"; refresh()
                        case .failure: message = "복사 실패 · 원본은 유지됩니다"
                        }
                    }
                }
            }
        }
    }
}
