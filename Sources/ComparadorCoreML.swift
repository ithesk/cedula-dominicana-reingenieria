import Foundation
import UIKit
import Vision
import CoreML

/// Comparador facial 1:1 con un modelo Core ML de embeddings (MobileFaceNet / ArcFace).
///
/// Esto es el **máximo local de emparejamiento**: embeddings faciales reales, distancia
/// coseno, todo en el Neural Engine y sin red. La precisión de matching es de nivel
/// producción (≈99 % en LFW con un buen modelo).
///
/// El modelo no se incluye en el repositorio (licencia + tamaño). Para activarlo:
///   1. Convierte un MobileFaceNet/ArcFace a Core ML con `coremltools`.
///   2. Añade `FaceEmbedding.mlmodel` al target (entrada 112×112 RGB, salida vector).
/// Si el modelo no está, cae automáticamente a Vision (orientativo) sin romper el flujo.
struct ComparadorCoreML: ComparadorFacial {
    let nombre: String
    let aptoProduccion: Bool
    let haceLiveness = false          // el liveness lo aporta ARKit, no el comparador
    var umbral: Double = 0.62         // coseno; calibrar con el modelo concreto

    private let modelo: VNCoreMLModel?
    private let respaldo = ComparadorVision()

    init() {
        if let m = ComparadorCoreML.cargarModelo() {
            modelo = m
            nombre = "Core ML · embeddings faciales"
            aptoProduccion = true      // matching de nivel producción (liveness aparte)
        } else {
            modelo = nil
            nombre = "Apple Vision (orientativo · falta modelo Core ML)"
            aptoProduccion = false
        }
    }

    private static func cargarModelo() -> VNCoreMLModel? {
        // Busca cualquier .mlmodelc compilado con un nombre habitual.
        let nombres = ["FaceEmbedding", "MobileFaceNet", "arcface", "face"]
        for n in nombres {
            if let url = Bundle.main.url(forResource: n, withExtension: "mlmodelc"),
               let ml = try? MLModel(contentsOf: url),
               let vn = try? VNCoreMLModel(for: ml) {
                return vn
            }
        }
        return nil
    }

    func comparar(selfie: UIImage, referencia: UIImage) -> ResultadoFacial {
        guard let modelo else {
            // Sin modelo: reusar el comparador de Vision, pero marcado como no apto.
            return respaldo.comparar(selfie: selfie, referencia: referencia)
        }

        guard let a = recortarCara(selfie) else { return sinCara(selfieOK: false) }
        guard let b = recortarCara(referencia) else { return sinCara(selfieOK: true) }
        guard let ea = embedding(a, modelo), let eb = embedding(b, modelo) else {
            return ResultadoFacial(caraEnSelfie: true, caraEnReferencia: true, puntuacion: nil,
                                   umbral: umbral, livenessComprobado: false, aptoProduccion: true,
                                   motivo: "El modelo no devolvió embedding.")
        }

        let sim = max(0, Double(coseno(ea, eb)))   // 0…1
        return ResultadoFacial(caraEnSelfie: true, caraEnReferencia: true, puntuacion: sim,
                               umbral: umbral, livenessComprobado: false, aptoProduccion: true,
                               motivo: "Emparejamiento 1:1 con embeddings faciales (Core ML). Matching de nivel producción; la vida la comprueba ARKit.")
    }

    // MARK: - Núcleo

    private func embedding(_ cara: CGImage, _ modelo: VNCoreMLModel) -> [Float]? {
        let req = VNCoreMLRequest(model: modelo)
        req.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cara, options: [:])
        try? handler.perform([req])
        if let obs = req.results?.first as? VNCoreMLFeatureValueObservation,
           let arr = obs.featureValue.multiArrayValue {
            return (0..<arr.count).map { Float(truncating: arr[$0]) }
        }
        return nil
    }

    private func coseno(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
        let d = sqrt(na) * sqrt(nb)
        return d > 0 ? dot / d : 0
    }

    private func recortarCara(_ imagen: UIImage) -> CGImage? {
        guard let cg = imagen.cgNormalizado() else { return nil }
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        guard let cara = (req.results ?? [])
            .max(by: { $0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height })
        else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var r = CGRect(x: cara.boundingBox.minX*w, y: (1-cara.boundingBox.maxY)*h,
                       width: cara.boundingBox.width*w, height: cara.boundingBox.height*h)
        r = r.insetBy(dx: -r.width*0.15, dy: -r.height*0.15)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return cg.cropping(to: r)
    }

    private func sinCara(selfieOK: Bool) -> ResultadoFacial {
        ResultadoFacial(caraEnSelfie: selfieOK, caraEnReferencia: false, puntuacion: nil,
                        umbral: umbral, livenessComprobado: false, aptoProduccion: true,
                        motivo: selfieOK ? "Sin cara en la foto del chip." : "Sin cara en el selfie.")
    }
}
