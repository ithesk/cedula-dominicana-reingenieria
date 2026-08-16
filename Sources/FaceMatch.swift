import Foundation
import SwiftUI
import UIKit
import Vision

/// Fase 3 — ¿quien presenta la cédula es el titular?
///
/// Se compara un selfie en vivo contra la foto del chip (DG2). El comparador 1:1 de
/// producción y el anti-spoofing (liveness) **no se construyen a mano**: se «alquilan» a un
/// SDK (Regula, FaceTec, Innovatrics, Didit…). Aquí queda todo el andamiaje —captura,
/// detección de cara, flujo, veredicto— y el comparador como un **hueco enchufable**
/// (`ComparadorFacial`). El de relleno usa Apple Vision y es solo orientativo.

struct ResultadoFacial {
    var caraEnSelfie: Bool
    var caraEnReferencia: Bool
    var puntuacion: Double?      // 0…1 (mayor = más parecido)
    var umbral: Double
    var livenessComprobado: Bool // false mientras no haya SDK
    var aptoProduccion: Bool     // false con el comparador Vision
    var motivo: String

    var coincide: Bool? {
        guard let p = puntuacion else { return nil }
        return p >= umbral
    }

    var veredicto: VeredictoTitular {
        if !caraEnSelfie { return .sinCaraSelfie }
        if !caraEnReferencia { return .sinCaraReferencia }
        guard let ok = coincide else { return .indeterminado }
        return ok ? .probablesElMismo : .probablesDistintos
    }
}

enum VeredictoTitular {
    case probablesElMismo, probablesDistintos, indeterminado
    case sinCaraSelfie, sinCaraReferencia

    var titulo: String {
        switch self {
        case .probablesElMismo:    return "Coincidencia probable"
        case .probablesDistintos:  return "No coincide"
        case .indeterminado:       return "Indeterminado"
        case .sinCaraSelfie:       return "No se detectó cara en el selfie"
        case .sinCaraReferencia:   return "No se detectó cara en la foto del chip"
        }
    }
    var nivel: NivelSeguridad {
        switch self {
        case .probablesElMismo:   return .ok
        case .probablesDistintos: return .critico
        default:                  return .aviso
        }
    }
    var simbolo: String {
        switch self {
        case .probablesElMismo:   return "person.crop.circle.badge.checkmark"
        case .probablesDistintos: return "person.crop.circle.badge.xmark"
        default:                  return "person.crop.circle.badge.questionmark"
        }
    }
}

/// El hueco del SDK. Un producto real implementa esto y se enchufa sin tocar nada más.
protocol ComparadorFacial {
    var nombre: String { get }
    var aptoProduccion: Bool { get }
    var haceLiveness: Bool { get }
    func comparar(selfie: UIImage, referencia: UIImage) -> ResultadoFacial
}

/// Comparador de relleno con Apple Vision.
///
/// ⚠️ ORIENTATIVO. Vision detecta caras y calcula «feature prints» de imagen, pero eso
/// **no es** verificación facial 1:1 ni tiene anti-spoofing: una foto de una foto pasaría.
/// Sirve para probar el flujo, no para decidir identidad en producción.
struct ComparadorVision: ComparadorFacial {
    let nombre = "Apple Vision (orientativo)"
    let aptoProduccion = false
    let haceLiveness = false
    var umbral: Double = 0.55

    func comparar(selfie: UIImage, referencia: UIImage) -> ResultadoFacial {
        let caraSelfie = recortarCara(selfie)
        let caraRef = recortarCara(referencia)

        guard let s = caraSelfie else {
            return ResultadoFacial(caraEnSelfie: false, caraEnReferencia: caraRef != nil,
                                   puntuacion: nil, umbral: umbral, livenessComprobado: false,
                                   aptoProduccion: false, motivo: "Sin cara en el selfie.")
        }
        guard let r = caraRef else {
            return ResultadoFacial(caraEnSelfie: true, caraEnReferencia: false,
                                   puntuacion: nil, umbral: umbral, livenessComprobado: false,
                                   aptoProduccion: false, motivo: "Sin cara en la foto del chip.")
        }

        let puntuacion = similitud(s, r)
        return ResultadoFacial(caraEnSelfie: true, caraEnReferencia: true,
                               puntuacion: puntuacion, umbral: umbral, livenessComprobado: false,
                               aptoProduccion: false,
                               motivo: "Similitud orientativa de Vision. No es verificación 1:1 ni comprueba que sea una persona viva.")
    }

    // MARK: - Vision

    /// Detecta la cara mayor y devuelve un recorte cuadrado alrededor de ella.
    private func recortarCara(_ imagen: UIImage) -> CGImage? {
        guard let cg = imagen.cgNormalizado() else { return nil }
        let peticion = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([peticion])
        guard let cara = (peticion.results ?? [])
            .max(by: { $0.boundingBox.area < $1.boundingBox.area }) else { return nil }

        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // Vision usa origen abajo-izquierda; se convierte a píxeles y se amplía un 40 %.
        var rect = CGRect(x: cara.boundingBox.minX * w,
                          y: (1 - cara.boundingBox.maxY) * h,
                          width: cara.boundingBox.width * w,
                          height: cara.boundingBox.height * h)
        rect = rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.2)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return cg.cropping(to: rect)
    }

    /// Distancia entre «feature prints» de las dos caras, mapeada a 0…1.
    private func similitud(_ a: CGImage, _ b: CGImage) -> Double? {
        guard let fa = featurePrint(a), let fb = featurePrint(b) else { return nil }
        var distancia = Float(0)
        do { try fa.computeDistance(&distancia, to: fb) } catch { return nil }
        // Feature prints de caras: distancias típicas ~0 (igual) … ~30 (distinto).
        // Mapeo suave a una puntuación 0…1 (orientativa, no calibrada).
        let s = max(0, 1 - Double(distancia) / 28.0)
        return s
    }

    private func featurePrint(_ cg: CGImage) -> VNFeaturePrintObservation? {
        let peticion = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([peticion])
        return peticion.results?.first as? VNFeaturePrintObservation
    }
}

extension VNFaceObservation {
    var boundingBoxArea: CGFloat { boundingBox.width * boundingBox.height }
}
private extension CGRect { var area: CGFloat { width * height } }

extension UIImage {
    /// Devuelve un CGImage con la orientación ya aplicada (Vision ignora `imageOrientation`).
    func cgNormalizado() -> CGImage? {
        if imageOrientation == .up, let cg = cgImage { return cg }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normal = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normal?.cgImage
    }
}
