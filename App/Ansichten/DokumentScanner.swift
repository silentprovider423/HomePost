import SwiftUI
import VisionKit

/// Dokument scannen (VisionKit) → PDF-Anhang, wie Apples „Dokument scannen“ beim Verfassen.
struct DokumentScanner: UIViewControllerRepresentable {
    let fertig: (AusgehenderAnhang?) -> Void

    static var verfuegbar: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Koordinator { Koordinator(fertig: fertig) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Koordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let fertig: (AusgehenderAnhang?) -> Void
        init(fertig: @escaping (AusgehenderAnhang?) -> Void) { self.fertig = fertig }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let daten = NSMutableData()
            UIGraphicsBeginPDFContextToData(daten, .zero, nil)
            for i in 0..<scan.pageCount {
                let bild = scan.imageOfPage(at: i)
                UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: bild.size), nil)
                bild.draw(at: .zero)
            }
            UIGraphicsEndPDFContext()
            fertig(AusgehenderAnhang(name: String(localized: "Gescanntes Dokument") + ".pdf", mimeTyp: "application/pdf",
                                     daten: daten as Data))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { fertig(nil) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { fertig(nil) }
    }
}
