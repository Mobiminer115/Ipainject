import Combine
import Foundation

@MainActor
final class ForgeViewModel: ObservableObject {
    enum PickerRequest: String, Hashable, Identifiable {
        case ipa
        case payload

        var id: String { rawValue }
    }

    @Published var preparedIPA: PreparedIPA?
    @Published var preparedPayload: PreparedPayload?
    @Published var selectedExecutableID = ""
    @Published var selectedAssetIDs = Set<UUID>()

    @Published var destination: DestinationLocation = .frameworks
    @Published var referenceRoot: LoadReferenceRoot = .rpath
    @Published var rpathChoice: RPathChoice = .automatic
    @Published var customRPath = ""
    @Published var weakLoad = false
    @Published var replaceExisting = false
    @Published var confirmsAuthorization = false

    @Published var pickerRequest: PickerRequest?
    @Published var isBusy = false
    @Published var statusText = ""
    @Published var errorMessage = ""
    @Published var showsError = false
    @Published var result: PatchPipelineResult?

    var selectedExecutable: ExecutableCandidate? {
        preparedIPA?.executables.first(where: { $0.id == selectedExecutableID })
    }

    var selectedAssets: [PreparedPayloadAsset] {
        preparedPayload?.assets.filter { selectedAssetIDs.contains($0.id) } ?? []
    }

    var canRun: Bool {
        preparedIPA != nil
            && selectedExecutable != nil
            && !selectedAssets.isEmpty
            && confirmsAuthorization
            && !isBusy
    }

    func chooseIPA() {
        guard !isBusy else { return }
        pickerRequest = .ipa
    }

    func choosePayload() {
        guard !isBusy else { return }
        pickerRequest = .payload
    }

    func handlePickedURLs(_ urls: [URL], for request: PickerRequest) {
        pickerRequest = nil
        guard let url = urls.first else { return }
        isBusy = true
        statusText = request == .ipa ? "Đang kiểm tra IPA…" : "Đang đọc payload…"
        result = nil

        Task {
            var stagedURL: URL?
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try StagingService.stage(url)
                }.value
                stagedURL = staged

                switch request {
                case .ipa:
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try IPAArchiveService.prepare(staged)
                    }.value
                    if let oldRoot = preparedIPA?.extractionRoot { try? FileManager.default.removeItem(at: oldRoot) }
                    preparedIPA = prepared
                    selectedExecutableID = prepared.executables.first(where: \.isMainExecutable)?.id
                        ?? prepared.executables.first?.id
                        ?? ""
                case .payload:
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try PayloadPreparationService.prepare(staged)
                    }.value
                    if let oldRoot = preparedPayload?.workspaceRoot { try? FileManager.default.removeItem(at: oldRoot) }
                    preparedPayload = prepared
                    selectedAssetIDs = Set(prepared.assets.map(\.id))
                }
            } catch {
                present(error)
            }
            if let stagedURL {
                try? FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent())
            }
            statusText = ""
            isBusy = false
        }
    }

    func toggleAsset(_ asset: PreparedPayloadAsset) {
        if selectedAssetIDs.contains(asset.id) {
            selectedAssetIDs.remove(asset.id)
        } else {
            selectedAssetIDs.insert(asset.id)
        }
        result = nil
    }

    func run() {
        guard let ipa = preparedIPA,
              let target = selectedExecutable,
              !selectedAssets.isEmpty,
              confirmsAuthorization else { return }

        let assets = selectedAssets
        let options = InjectionOptions(
            destination: destination,
            referenceRoot: referenceRoot,
            rpathChoice: rpathChoice,
            customRPath: customRPath,
            weakLoad: weakLoad,
            replaceExisting: replaceExisting
        )

        isBusy = true
        statusText = "Đang tạo bản IPA đã nhúng…"
        result = nil
        Task {
            do {
                result = try await Task.detached(priority: .userInitiated) {
                    try PatchPipeline.run(ipa: ipa, target: target, assets: assets, options: options)
                }.value
            } catch {
                present(error)
            }
            statusText = ""
            isBusy = false
        }
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showsError = true
    }
}
