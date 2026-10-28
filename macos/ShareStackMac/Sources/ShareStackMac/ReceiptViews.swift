import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("수신 방식").font(.headline)
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

            VStack(alignment: .leading, spacing: 10) {
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
            .padding(12)
            .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(12)
            .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 0)
            Text(model.receiptMessage)
                .font(.caption)
                .lineLimit(1)
                .help(model.receiptMessage)
                .accessibilityLabel("처리 상태: \(model.receiptMessage)")
        }
        .modifier(HiddenFocusRing())
        .tint(StackDesign.accent)
    }
}

struct ReceiptInboxView: View {
    @ObservedObject var model: MacAppModel
    @State private var page = 0

    private let itemsPerPage = 6

    private var pageCount: Int {
        max(1, (model.inboxItems.count + itemsPerPage - 1) / itemsPerPage)
    }

    private var currentPage: Int {
        min(page, pageCount - 1)
    }

    private var visibleItems: [TransferItem] {
        Array(model.inboxItems.dropFirst(currentPage * itemsPerPage).prefix(itemsPerPage))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("보관함").font(.system(size: 16, weight: .semibold))
                Text("\(model.inboxItems.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(StackDesign.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StackDesign.accent.opacity(0.12), in: Capsule())
                Spacer()
                if model.isReceiving { ProgressView().controlSize(.small) }
                Button { model.receiveAllInboxItems() } label: {
                    Label("전체 수신", systemImage: "arrow.down.to.line")
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.inboxItems.isEmpty || model.isReceiving)
            }
            if !model.inboxItems.isEmpty {
                Label(model.receiptSettings.folderPath, systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.receiptSettings.folderPath)
                VStack(spacing: 4) {
                    ForEach(visibleItems) { item in
                        HStack(spacing: 8) {
                            Image(systemName: StackDesign.fileSymbol(item.mimeType))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(StackDesign.accent)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .help(item.name)
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let error = item.saveError {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .help(error)
                                    .accessibilityLabel("자동 저장 실패: \(error)")
                            }
                            Button("수신") { model.receiveInboxItem(item) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(StackDesign.accent)
                                .accessibilityLabel("\(item.name) 수신")
                            Button { model.addInboxItemToAIExchange(item) } label: {
                                Image(systemName: "sparkles")
                                    .frame(width: 22, height: 28)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .help("AI Exchange로 복사")
                                .accessibilityLabel("\(item.name)을 AI Exchange로 복사")
                            Button(role: .destructive) { model.cancelInboxItem(item) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 22, height: 28)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("이 파일의 임시 보관본을 삭제합니다.")
                                .accessibilityLabel("\(item.name) 취소 및 임시 파일 삭제")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .disabled(model.isReceiving)
                Spacer(minLength: 0)
                if pageCount > 1 {
                    HStack {
                    Button("이전") { page = currentPage - 1 }
                        .disabled(currentPage == 0 || model.isReceiving)
                    Spacer()
                    Text("\(currentPage + 1) / \(pageCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("다음") { page = currentPage + 1 }
                        .disabled(currentPage + 1 >= pageCount || model.isReceiving)
                }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(StackDesign.accent)
                        .frame(width: 68, height: 68)
                        .background(StackDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                    Text("수신 대기 없음")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            if !model.receiptMessage.isEmpty {
                Text(model.receiptMessage)
                    .font(.caption)
                    .lineLimit(2)
                    .help(model.receiptMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("처리 상태: \(model.receiptMessage)")
            }
        }
        .tint(StackDesign.accent)
        .onAppear { model.refresh() }
        .onChange(of: model.inboxItems.count) { _ in page = currentPage }
    }
}

struct AIExchangeView: View {
    @ObservedObject var model: MacAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI Exchange").font(.system(size: 16, weight: .semibold))
                Text("\(model.aiExchangeItems.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(StackDesign.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StackDesign.accent.opacity(0.12), in: Capsule())
                Spacer()
                if model.isReceiving { ProgressView().controlSize(.small) }
            }
            Toggle("AI 전체 읽기 허용", isOn: Binding(
                get: { model.aiExchangeEnabled },
                set: { model.setAIExchangeEnabled($0) }
            ))
                .font(.system(size: 12, weight: .medium))
                .disabled(model.isReceiving)
            Text("AI는 여기에 명시적으로 복사한 파일만 읽을 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if !model.savedReceivedItems.isEmpty {
                        Text("수신 완료 파일에서 복사")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(model.savedReceivedItems) { item in
                            HStack(spacing: 8) {
                                Image(systemName: StackDesign.fileSymbol(item.mimeType))
                                    .foregroundStyle(StackDesign.accent).frame(width: 25)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button { model.addInboxItemToAIExchange(item) } label: {
                                    Image(systemName: "sparkles").frame(width: 24, height: 28)
                                }
                                .buttonStyle(.plain)
                                .help("AI Exchange로 복사")
                                .accessibilityLabel("\(item.name)을 AI Exchange로 복사")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    Text("AI Exchange 파일")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if model.aiExchangeItems.isEmpty {
                        Text("등록된 파일이 없습니다. 보관함에서 파일 옆의 ✨ 버튼을 눌러 복사하세요.")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(model.aiExchangeItems) { file in
                        HStack(spacing: 8) {
                            Image(systemName: StackDesign.fileSymbol(file.mimeType))
                                .foregroundStyle(StackDesign.accent).frame(width: 25)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button(role: .destructive) { model.deleteAIExchangeItem(file) } label: {
                                Image(systemName: "trash").frame(width: 24, height: 28)
                            }
                            .buttonStyle(.plain)
                            .help("AI Exchange에서 삭제")
                            .accessibilityLabel("\(file.name) AI Exchange에서 삭제")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .disabled(model.isReceiving)
            if !model.receiptMessage.isEmpty {
                Text(model.receiptMessage).font(.caption).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { model.refresh() }
    }
}
