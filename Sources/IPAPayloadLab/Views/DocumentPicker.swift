import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DocumentPicker: UIViewControllerRepresentable {
    let request: ForgeViewModel.PickerRequest
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType]
        switch request {
        case .ipa:
            // File providers do not consistently advertise .ipa as ZIP or as
            // our imported UTI. Let the user select any file and validate the
            // extension/archive after the picker returns it.
            types = [.item]
        case .payload:
            // .item keeps dylib/deb/framework packages selectable even when a
            // provider reports only public.data; .folder permits flat framework
            // directories exposed as ordinary folders.
            types = [.item, .folder]
        }
        // Import a provider-managed copy instead of requesting open-in-place.
        // StagingService immediately copies it into this app's own temporary
        // workspace before inspection or patching.
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
