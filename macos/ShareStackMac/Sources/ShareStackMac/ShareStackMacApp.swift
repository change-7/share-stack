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
        popover.contentSize = NSSize(width: 360, height: 488)
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
        model.filesArrivedHandler = { [weak self] in
            guard let self else { return }
            if UserDefaults.standard.object(forKey: "arrivalSound") as? Bool ?? true {
                NSSound(named: NSSound.Name("Glass"))?.play()
            }
            if UserDefaults.standard.object(forKey: "arrivalShowLibrary") as? Bool ?? true {
                self.preparePopoverContent()
                self.model.menuSection = 0
                NSApplication.shared.activate(ignoringOtherApps: true)
                if !self.popover.isShown, let button = self.statusItem?.button {
                    self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
                self.popover.contentViewController?.view.window?.makeKey()
            }
        }
        badgeSubscription = model.$libraryItems
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
        button.toolTip = count > 0 ? "Share Stack · 보관함 \(count)개" : "Share Stack"
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
    @Published var libraryItems: [LibraryItem] = []
    @Published var aiReadProgress: [String: Double] = [:]
    @Published private var aiReadOverrides: [String: Bool] = [:]
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

    private var aiReadIntents: [String: AIReadPreparation] = [:]
    private var aiReadPending = Set<String>()
    private var aiReadTasks: [String: Task<Void, Never>] = [:]
    private var locallyRevokedAIIDs = Set<String>()
    private let aiPreparationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.pdg.sharestack.ai-preparation"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
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

    var filesArrivedHandler: (() -> Void)?
    private var arrivalTracker = LibraryArrivalTracker()

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
                self.aiReadOverrides = self.aiReadOverrides.filter { self.aiReadPending.contains($0.key) }
                let pendingFileIDs = Set(self.libraryItems.filter { self.aiReadPending.contains($0.id) }.compactMap { $0.exchange?.id })
                self.locallyRevokedAIIDs.formIntersection(pendingFileIDs)
                self.rebuildLibrary()
                if self.arrivalTracker.update(Set(self.libraryItems.map(\.id))) {
                    self.filesArrivedHandler?()
                }
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
        if let row = libraryItems.first(where: { $0.id == item.id }) { setAIReadAllowed(false, for: row) }
        isReceiving = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try store.cancelReceivedItem(item.id)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReceiving = false
                switch result {
                case .success: self.receiptMessage = item.state == "saved" ? "보관함에서 제거됨 · 저장된 파일은 유지됩니다." : "취소됨 · 임시 파일을 삭제했습니다."
                case .failure(let error): self.receiptMessage = "취소 실패 · \(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    private func rebuildLibrary() {
        let rows = LibraryItem.combine(inbox: inboxItems, saved: savedReceivedItems, exchange: aiExchangeItems)
        if libraryItems != rows { libraryItems = rows }
        let liveIDs = Set(rows.map(\.id))
        aiReadOverrides = aiReadOverrides.filter { liveIDs.contains($0.key) }
        for id in Array(aiReadIntents.keys) where !liveIDs.contains(id) {
            if aiReadProgress[id] != nil { aiReadIntents[id]?.cancel() }
            aiReadIntents.removeValue(forKey: id)
            aiReadTasks.removeValue(forKey: id)?.cancel()
            aiReadProgress.removeValue(forKey: id)
        }
    }

    func aiReadChecked(_ item: LibraryItem) -> Bool {
        if let progress = aiReadProgress[item.id], progress < 1 { return false }
        if let allowed = aiReadOverrides[item.id] { return allowed }
        return item.exchange.map {
            $0.aiReadAllowed == true && !locallyRevokedAIIDs.contains($0.id)
        } ?? false
    }

    func setAIReadAllowed(_ enabled: Bool, for item: LibraryItem) {
        guard let store else { return }
        let committedID = aiReadIntents[item.id]?.cancel()
        aiReadTasks.removeValue(forKey: item.id)?.cancel()
        let fileID = committedID ?? item.exchange?.id
        let preparation = store.makeAIReadPreparation(sourceID: item.transfer?.id, fileID: fileID)
        aiReadIntents[item.id] = preparation
        aiReadPending.insert(item.id)
        if !enabled {
            if let sourceID = item.transfer?.id { store.invalidateAIReadPreparation(sourceID: sourceID) }
            aiReadOverrides[item.id] = false
            aiReadProgress.removeValue(forKey: item.id)
            if let fileID {
                locallyRevokedAIIDs.insert(fileID)
                store.denyAIReadImmediately(fileID)
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result {
                    try preparation.check()
                    if let sourceID = item.transfer?.id { try store.revokePhoneConsentFromMac(sourceID: sourceID, preparation: preparation) }
                    if let fileID {
                        do { try store.revokeAIRead(fileID, preparation: preparation) }
                        catch TransferStore.StoreError.sharedFileNotFound {}
                    }
                }
                DispatchQueue.main.async {
                    guard let self, self.aiReadIntents[item.id] === preparation else { return }
                    self.aiReadPending.remove(item.id)
                    if case .failure(let error) = result, !(error is CancellationError) {
                        self.receiptMessage = "AI 읽기는 차단됐으나 설정 저장 실패 · \(error.localizedDescription)"
                    } else { self.receiptMessage = "AI 읽기 허용을 해제했습니다." }
                    self.refresh()
                }
            }
            return
        }
        aiReadProgress[item.id] = 0
        withAnimation(.linear(duration: AIReadPreparation.delay)) { aiReadProgress[item.id] = 0.8 }
        aiReadTasks[item.id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(AIReadPreparation.delay * 1_000_000_000))
                try preparation.check()
            } catch { return }
            guard let self, self.aiReadIntents[item.id] === preparation else { return }
            self.aiPreparationQueue.addOperation { [weak self] in
                var lastPercent = -1
                let result = Result {
                    try store.prepareAIRead(sourceID: item.transfer?.id, fileID: fileID, preparation: preparation) { value in
                        let percent = Int(min(1, max(0, value)) * 100)
                        guard percent > lastPercent else { return }
                        lastPercent = percent
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.aiReadIntents[item.id] === preparation,
                                  self.aiReadProgress[item.id] != nil else { return }
                            withAnimation(.linear(duration: 0.2)) {
                                self.aiReadProgress[item.id] = 0.8 + 0.15 * Double(percent) / 100
                            }
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let self, self.aiReadIntents[item.id] === preparation else { return }
                    self.aiReadTasks.removeValue(forKey: item.id)
                    self.aiReadPending.remove(item.id)
                    switch result {
                    case .success(let file):
                        self.aiReadOverrides[item.id] = true
                        withAnimation(.linear(duration: 0.2)) { self.aiReadProgress[item.id] = 1 }
                        self.aiReadTasks[item.id] = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard let self, self.aiReadIntents[item.id] === preparation else { return }
                            self.aiReadProgress.removeValue(forKey: item.id)
                            self.aiReadTasks.removeValue(forKey: item.id)
                        }
                        self.locallyRevokedAIIDs.remove(file.id)
                        self.aiExchangeItems.removeAll { $0.id == file.id }
                        self.aiExchangeItems.insert(file, at: 0)
                        self.rebuildLibrary()
                        self.receiptMessage = "AI 읽기를 허용했습니다 · \(file.name)"
                    case .failure(let error):
                        self.aiReadOverrides[item.id] = false
                        self.aiReadProgress.removeValue(forKey: item.id)
                        if !(error is CancellationError) { self.receiptMessage = "AI 공개 준비 실패 · \(error.localizedDescription)" }
                    }
                    self.refresh()
                }
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
        if let row = libraryItems.first(where: { $0.id == item.id }) { setAIReadAllowed(false, for: row) }
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

    func sendSelectedToGalaxy(_ ids: Set<String>) {
        guard let store, !ids.isEmpty else { return }
        enqueueForGalaxy {
            for id in ids { try store.queueLibraryItemForPhone(id) }
        }
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
            HStack(spacing: 8) {
                Picker("메뉴", selection: $model.menuSection) {
                    Text("보관함").tag(0)
                    Text("연결").tag(1)
                    Text("설정").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 4) {
                    Circle()
                        .fill(hasError ? Color.orange : (model.certificateFingerprint.isEmpty ? Color.secondary : StackDesign.accent))
                        .frame(width: 5, height: 5)
                    Text(model.status)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 110, alignment: .trailing)
                .help(model.status)
                .accessibilityLabel(model.status)
            }

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

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)

            if model.menuSection == 0 {
            HStack(spacing: 8) {
                Button { model.addFiles() } label: {
                    Label("파일 보내기", systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.certificateFingerprint.isEmpty || model.isReceiving)
            }

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
        .frame(width: 360, height: 488)
        .modifier(HiddenFocusRing())
        .background(.regularMaterial)
        .tint(StackDesign.accent)
        .onAppear { model.refresh() }
    }

}
