import SwiftUI

struct ContentView: View {
    @StateObject private var model = ForgeViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    introCard
                    ipaCard
                    payloadCard
                    optionsCard
                    authorizationCard
                    actionArea
                    if let result = model.result {
                        resultCard(result)
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("IPA Payload Lab")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $model.pickerRequest) { request in
            DocumentPicker(
                request: request,
                onPick: { model.handlePickedURLs($0, for: request) },
                onCancel: { model.pickerRequest = nil }
            )
        }
        .alert("Không thể tiếp tục", isPresented: $model.showsError) {
            Button("Đóng", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }

    private var introCard: some View {
        SectionCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nhúng payload vào bản sao IPA")
                        .font(.headline)
                    Text("Mọi xử lý diễn ra trong vùng dữ liệu của app. File xuất ra chưa được ký và không sửa app đang cài trên máy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ipaCard: some View {
        SectionCard(title: "1. IPA nguồn") {
            Button(action: model.chooseIPA) {
                Label(model.preparedIPA == nil ? "Chọn file IPA" : "Đổi file IPA", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)

            if let ipa = model.preparedIPA {
                Divider()
                SummaryRow(label: "Ứng dụng", value: ipa.displayName)
                SummaryRow(label: "Bundle ID", value: ipa.bundleIdentifier, monospaced: true)
                SummaryRow(label: "Phiên bản", value: ipa.version)

                Picker("Executable", selection: $model.selectedExecutableID) {
                    ForEach(ipa.executables) { candidate in
                        Text(candidate.displayName).tag(candidate.id)
                    }
                }
                .pickerStyle(.menu)

                if let executable = model.selectedExecutable {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(executable.relativePath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("\(executable.architectures.joined(separator: ", ")) • header slack tối thiểu \(executable.headerSlack) byte")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var payloadCard: some View {
        SectionCard(title: "2. Payload") {
            Button(action: model.choosePayload) {
                Label(model.preparedPayload == nil ? "Chọn Dylib / Framework / DEB" : "Đổi payload", systemImage: "puzzlepiece.extension")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)

            if let payload = model.preparedPayload {
                Divider()
                Text(payload.sourceName)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(payload.assets) { asset in
                    Button {
                        model.toggleAsset(asset)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.selectedAssetIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.selectedAssetIDs.contains(asset.id) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(asset.name)
                                    .foregroundStyle(.primary)
                                Text("\(asset.kind.title) • \(asset.architectures.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var optionsCard: some View {
        SectionCard(title: "3. Tùy chọn load") {
            Picker("Vị trí nhúng", selection: $model.destination) {
                ForEach(DestinationLocation.allCases) { item in
                    Text(item.title).tag(item)
                }
            }

            Picker("Kiểu tham chiếu", selection: $model.referenceRoot) {
                ForEach(LoadReferenceRoot.allCases) { item in
                    Text(item.token).tag(item)
                }
            }

            Picker("RPATH thêm vào", selection: $model.rpathChoice) {
                ForEach(RPathChoice.allCases) { item in
                    Text(item.title).tag(item)
                }
            }

            if model.rpathChoice == .custom {
                TextField("@executable_path/Frameworks", text: $model.customRPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }

            Toggle("Dùng weak load", isOn: $model.weakLoad)
            Toggle("Ghi đè payload trùng tên", isOn: $model.replaceExisting)

            if model.referenceRoot == .rpath && model.rpathChoice == .none {
                Label("Chỉ chọn “Không thêm” khi executable đã có RPATH phù hợp.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var authorizationCard: some View {
        SectionCard {
            Toggle(isOn: $model.confirmsAuthorization) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tôi có quyền sửa IPA này")
                        .font(.subheadline.weight(.semibold))
                    Text("Không dùng cho app của bên khác khi chưa được phép.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Label("Sau khi nhúng, chữ ký cũ không còn hợp lệ. Bạn phải ký lại toàn bộ bundle bằng chứng thư của mình trước khi cài.", systemImage: "signature")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if model.isBusy {
            SectionCard {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(model.statusText)
                        .font(.subheadline)
                    Spacer()
                }
            }
        }

        Button(action: model.run) {
            Label("Tạo IPA đã nhúng", systemImage: "hammer.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canRun)
    }

    private func resultCard(_ result: PatchPipelineResult) -> some View {
        SectionCard(title: "Hoàn tất") {
            Label("Đã tạo và kiểm tra lại IPA", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            SummaryRow(label: "Executable", value: result.executable, monospaced: true)
            SummaryRow(label: "Payload", value: "\(result.assets.count)")
            SummaryRow(label: "Load command mới", value: "\(result.patchReport.totalCommandsAdded)")

            ForEach(result.assets) { asset in
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.name).font(.subheadline.weight(.semibold))
                    Text(asset.loadPath).font(.caption.monospaced())
                    Text(asset.destination).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ShareLink(item: result.outputURL) {
                Label("Chia sẻ IPA chưa ký", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct SectionCard<Content: View>: View {
    private let title: String?
    private let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if monospaced {
                Text(value)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .multilineTextAlignment(.trailing)
            }
        }
        .font(.subheadline)
    }
}
