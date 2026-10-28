import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

@main
enum ShareStackEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer().run()
        } else {
            ShareStackMacApp.main()
        }
    }
}

struct ShareStackMacApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBarController

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    lazy var model = MacAppModel()
    private var badgeSubscription: AnyCancellable?
    private var localEventMonitor: Any?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.contentSize = NSSize(width: 360, height: 540)
        popover.behavior = .applicationDefined
        popover.animates = false

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Share Stack")
            button.toolTip = "Share Stack"
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item
        badgeSubscription = model.$inboxItems
            .map { $0.count }
            .removeDuplicates()
            .sink { [weak self] count in self?.updateBadge(count) }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.popover.performClose(nil)
                    return nil
                }
            } else if event.window !== self.popover.contentViewController?.view.window,
                      event.window !== self.statusItem?.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    /// SwiftUI 뷰 그래프는 메뉴를 처음 열 때 만든다. 시작 시점에는 만들지 않는다.
    private func preparePopoverContent() {
        guard popover.contentViewController == nil else { return }
        let hostingController = NSHostingController(rootView: ShareStackMenu(model: model))
        hostingController.sizingOptions = []
        hostingController.view.focusRingType = .none
        popover.contentViewController = hostingController
    }

    private func updateBadge(_ count: Int) {
        guard let button = statusItem?.button,
              let symbol = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil) else { return }
        let title = count > 99 ? "99+" : String(count)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let textSize = title.size(withAttributes: attributes)
        let badgeWidth = max(16, ceil(textSize.width) + 8)
        let width = count > 0 ? 21 + badgeWidth : 18
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: 1, width: 18, height: 16))
            if count > 0 {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: 21, y: 1, width: badgeWidth, height: 16), xRadius: 8, yRadius: 8).fill()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                title.draw(at: NSPoint(x: 21 + (badgeWidth - textSize.width) / 2, y: (18 - textSize.height) / 2), withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        button.image = image
        button.toolTip = count > 0 ? "Share Stack · 수신 대기 \(count)개" : "Share Stack"
        button.setAccessibilityLabel(button.toolTip)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            preparePopoverContent()
            model.refresh()
            model.menuSection = 0
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@MainActor
final class MacAppModel: ObservableObject {
    @Published var status = "시작 중"
    @Published var addresses: [String] = []
    @Published var token = ""
    @Published var certificateFingerprint = ""
    @Published var inboxItems: [TransferItem] = []
    @Published var savedReceivedItems: [TransferItem] = []
    @Published var aiExchangeItems: [AIExchangeFile] = []
    @Published var aiExchangeEnabled = true
    @Published var receiptSettings = ReceiptSettings()
    @Published var receiptMessage = ""
    @Published var isReceiving = false
    @Published var menuSection = 0
    @Published var connectionRoute = ConnectionRoute.wifi

    enum ConnectionRoute: String {
        case wifi
        case tailscale
    }

    var connectionAddresses: [String] {
        addresses.filter {
            connectionRoute == .tailscale ? NetworkIdentity.isTailscaleIPv4($0) : NetworkIdentity.isPrivateIPv4($0)
        }
    }

    var pairingURL: String? {
        guard let address = connectionAddresses.first, !certificateFingerprint.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "sharestack"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: address),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "cert", value: certificateFingerprint)
        ]
        return components.url?.absoluteString
    }

    private var store: TransferStore?
    private var server: TransferHTTPServer?
    private var isRefreshing = false
    private var refreshRequested = false
    private var cachedPairingURL: String?
    private var cachedQRImage: NSImage?

    var pairingImage: NSImage? {
        guard let value = pairingURL else { return nil }
        if cachedPairingURL != value {
            cachedPairingURL = value
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(value.utf8)
            filter.correctionLevel = "M"
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) {
                let representation = NSCIImageRep(ciImage: output)
                let image = NSImage(size: representation.size)
                image.addRepresentation(representation)
                cachedQRImage = image
            } else {
                cachedQRImage = nil
            }
        }
        return cachedQRImage
    }

    init() {
        addresses = NetworkIdentity.localIPv4Addresses() + NetworkIdentity.tailscaleIPv4Addresses()
        do {
            let store = try TransferStore()
            self.store = store
            store.sharedItemsChangedHandler = { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
            self.receiptSettings = store.receiptSettings()
            refresh()
            let token = try NetworkIdentity.bearerToken()
            let aiToken = try NetworkIdentity.aiMCPBearerToken()
            let tlsIdentity = try TLSIdentity()
            let server = try TransferHTTPServer(store: store, token: token, aiToken: aiToken, tlsIdentity: tlsIdentity)
            try GUIBridge.publish(fingerprint: tlsIdentity.certificateFingerprint)
            self.server = server
            self.token = token
            self.certificateFingerprint = tlsIdentity.certificateFingerprint
            server.statusHandler = { [weak self] value in
                DispatchQueue.main.async { self?.status = value }
            }
            server.itemsChangedHandler = { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
            try server.start()
            refresh()
        } catch {
            status = "시작 실패 · \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard !isRefreshing else { refreshRequested = true; return }
        isRefreshing = true
        let store = store
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let addresses = NetworkIdentity.localIPv4Addresses() + NetworkIdentity.tailscaleIPv4Addresses()
            let inbox = store?.inboxItems() ?? []
            let savedReceivedItems = store?.savedReceivedItems() ?? []
            let exchangeItems = store?.aiExchangeItems() ?? []
            let exchangeEnabled = store?.aiExchangeEnabled() ?? true
            DispatchQueue.main.async {
                guard let self else { return }
                if self.addresses != addresses { self.addresses = addresses }
                if self.inboxItems != inbox { self.inboxItems = inbox }
                if self.savedReceivedItems != savedReceivedItems { self.savedReceivedItems = savedReceivedItems }
                if self.aiExchangeItems != exchangeItems { self.aiExchangeItems = exchangeItems }
                if self.aiExchangeEnabled != exchangeEnabled { self.aiExchangeEnabled = exchangeEnabled }
                self.isRefreshing = false
                if self.refreshRequested {
                    self.refreshRequested = false
                    self.refresh()
                }
            }
        }
    }

    func setReceiptMode(_ mode: ReceiptSettings.Mode) {
        var updated = receiptSettings
        updated.mode = mode
        saveReceiptSettings(updated)
    }

    func chooseReceiptFolder() {
        let panel = NSOpenPanel()
        panel.title = "수신 파일을 저장할 폴더 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: receiptSettings.folderPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = receiptSettings
        updated.folderPath = url.path
        saveReceiptSettings(updated)
    }

    func chooseInboxFolder() {
        let panel = NSOpenPanel()
        panel.title = "임시 보관 위치 선택"
        panel.message = "선택한 위치에 ShareStack Inbox 폴더를 만들고 기존 보관함 파일도 옮깁니다."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let path = receiptSettings.inboxFolderPath {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = receiptSettings
        updated.inboxFolderPath = url.appendingPathComponent("ShareStack Inbox", isDirectory: true).path
        saveReceiptSettings(updated)
    }

    private func saveReceiptSettings(_ value: ReceiptSettings) {
        guard let store, !isReceiving else { return }
        isReceiving = true
        receiptMessage = "설정 적용 중…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let message = try store.updateReceiptSettings(value)
                return (store.receiptSettings(), message)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReceiving = false
                switch result {
                case .success(let result):
                    self.receiptSettings = result.0
                    self.receiptMessage = result.1
                case .failure(let error): self.receiptMessage = "설정 저장 실패 · \(error.localizedDescription)"
                }
            }
        }
    }

    func receiveInboxItem(_ item: TransferItem) {
        receiveInboxItems([item])
    }

    func receiveAllInboxItems() {
        receiveInboxItems(inboxItems)
    }

    private func receiveInboxItems(_ items: [TransferItem]) {
        guard let store, !isReceiving, !items.isEmpty else { return }
        isReceiving = true
        receiptMessage = "\(items.count)개 파일을 저장하는 중입니다."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var saved = 0
            var firstError: String?
            for item in items {
                do {
                    try store.acceptReceivedItem(item.id)
                    saved += 1
                } catch {
                    if firstError == nil { firstError = "\(item.name) · \(error.localizedDescription)" }
                }
            }
            let savedCount = saved
            let failure = firstError
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReceiving = false
                if let failure {
                    self.receiptMessage = "\(savedCount)개 저장 · \(items.count - savedCount)개 실패: \(failure)"
                } else {
                    self.receiptMessage = "\(savedCount)개 파일을 지정 폴더에 저장했습니다."
                }
                self.refresh()
            }
        }
    }

    func cancelInboxItem(_ item: TransferItem) {
        guard let store, !isReceiving else { return }
        isReceiving = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try store.cancelReceivedItem(item.id) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReceiving = false
                switch result {
                case .success: self.receiptMessage = "취소됨 · 임시 파일을 삭제했습니다."
                case .failure(let error): self.receiptMessage = "취소 실패 · \(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    func addInboxItemToAIExchange(_ item: TransferItem) {
        guard let store, !isReceiving else { return }
        isReceiving = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try store.addInboxFileToAIExchange(item.id) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReceiving = false
                switch result {
                case .success(let file): self.receiptMessage = "AI Exchange에 복사됨 · \(file.name)"
                case .failure(let error): self.receiptMessage = "AI Exchange 등록 실패 · \(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    func setAIExchangeEnabled(_ enabled: Bool) {
        guard let store, !isReceiving else { return }
        isReceiving = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try store.setAIExchangeEnabled(enabled) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReceiving = false
                switch result {
                case .success: self.aiExchangeEnabled = enabled
                case .failure(let error): self.receiptMessage = "AI 읽기 설정 저장 실패 · \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteAIExchangeItem(_ item: AIExchangeFile) {
        guard let store, !isReceiving else { return }
        isReceiving = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try store.deleteAIExchangeFile(item.id) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReceiving = false
                switch result {
                case .success: self.receiptMessage = "AI Exchange 파일 삭제됨 · \(item.name)"
                case .failure(let error): self.receiptMessage = "AI Exchange 삭제 실패 · \(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    func addFiles() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        enqueueForGalaxy {
            for url in urls {
                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                _ = try store.enqueueFile(url, mimeType: mimeType)
            }
        }
    }

    func addClipboardText() {
        guard let store, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            status = "클립보드에 텍스트가 없음"
            return
        }
        enqueueForGalaxy { _ = try store.enqueueText(text) }
    }

    private func enqueueForGalaxy(_ work: @escaping () throws -> Void) {
        guard !isReceiving else { return }
        isReceiving = true
        status = "전송 파일 준비 중"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result(catching: work)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReceiving = false
                switch result {
                case .success: self.status = "갤럭시 전송 대기열에 추가됨"
                case .failure(let error): self.status = "전송 준비 실패 · \(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        status = "복사됨"
    }
}

private struct ShareStackMenu: View {
    @ObservedObject var model: MacAppModel

    private var hasError: Bool {
        model.status.contains("오류") || model.status.contains("실패")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StackBrandMark()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share Stack")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .tracking(-0.5)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(hasError ? Color.orange : (model.certificateFingerprint.isEmpty ? Color.secondary : StackDesign.accent))
                            .frame(width: 5, height: 5)
                        Text(model.status)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help(model.status)
                    .accessibilityLabel(model.status)
                }
                Spacer()
            }
            Picker("메뉴", selection: $model.menuSection) {
                Text("보관함").tag(0)
                Text("연결").tag(1)
                Text("설정").tag(2)
                Text("AI Exchange").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

                VStack(alignment: .leading, spacing: 12) {
                    if model.menuSection == 0 {
                        ReceiptInboxView(model: model)
                    }
                    if model.menuSection == 1 {
                        Picker("연결 경로", selection: $model.connectionRoute) {
                            Text("Wi-Fi").tag(MacAppModel.ConnectionRoute.wifi)
                            Text("Tailscale").tag(MacAppModel.ConnectionRoute.tailscale)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: model.connectionRoute) { _ in model.refresh() }
                    }
                    if model.menuSection == 1 {
                        VStack(alignment: .leading, spacing: 10) {
                            if let image = model.pairingImage {
                                Image(nsImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 112, height: 112)
                                    .padding(8)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text(model.connectionRoute == .tailscale ? "Tailscale 연결 필요" : "Wi-Fi 연결 필요")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.menuSection == 1 {
                                VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(model.connectionAddresses.first ?? "주소 없음").textSelection(.enabled)
                                            Spacer()
                                            Button("주소 복사") {
                                                if let address = model.connectionAddresses.first { model.copy(address) }
                                            }
                                            .disabled(model.connectionAddresses.isEmpty)
                                        }
                                    Button("토큰 복사") { model.copy(model.token) }
                                    HStack {
                                        Text("인증 지문").foregroundStyle(.secondary)
                                        Text(String(model.certificateFingerprint.prefix(12)) + (model.certificateFingerprint.isEmpty ? "" : "…"))
                                            .font(.system(.caption2, design: .monospaced))
                                            .help(model.certificateFingerprint)
                                        Spacer()
                                        Button("복사") { model.copy(model.certificateFingerprint) }
                                            .accessibilityLabel("인증 지문 복사")
                                    }
                                }
                                .font(.caption)
                                .padding(8)
                                .background(StackDesign.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if model.menuSection == 2 {
                        ReceiptSettingsView(model: model)
                    }
                    if model.menuSection == 3 {
                        AIExchangeView(model: model)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 8) {
                Button { model.addFiles() } label: {
                    Label("파일 보내기", systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity)
                }
                Button { model.addClipboardText() } label: {
                    Label("텍스트 보내기", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.certificateFingerprint.isEmpty || model.isReceiving)

            Divider()
            HStack {
                Button("새로고침") { model.refresh() }
                Spacer()
                Button("종료") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360, height: 540)
        .modifier(HiddenFocusRing())
        .background(.regularMaterial)
        .tint(StackDesign.accent)
        .onAppear { model.refresh() }
    }

}
