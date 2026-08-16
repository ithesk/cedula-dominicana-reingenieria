import SwiftUI
import UIKit

/// Captura un selfie con la cámara frontal. Es una captura estática: el liveness real
/// (comprobar que hay una persona viva delante) es trabajo del SDK, no de esto.
struct SelfiePicker: UIViewControllerRepresentable {
    var alCapturar: (UIImage) -> Void
    var alCancelar: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraDevice = .front
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinador { Coordinador(self) }

    final class Coordinador: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let padre: SelfiePicker
        init(_ padre: SelfiePicker) { self.padre = padre }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let imagen = info[.originalImage] as? UIImage {
                padre.alCapturar(imagen)
            } else {
                padre.alCancelar()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            padre.alCancelar()
        }
    }
}
