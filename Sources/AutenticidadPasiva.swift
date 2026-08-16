import Foundation
import SwiftUI
import NFCPassportReader

/// Fase 2 — Passive Authentication completa.
///
/// La cadena de confianza tiene tres eslabones. Dos se comprueban siempre, offline y sin
/// nada externo; el tercero necesita el certificado raíz de la JCE (CSCA), que se deja como
/// un **hueco configurable**: mientras no esté, el documento se declara «íntegro pero sin
/// anclar»; en cuanto se suelta el PEM del CSCA, el veredicto pasa a «genuino».
///
///   datos ──hash──▶ SOD ──firma──▶ DSC ──firma──▶ CSCA
///   └── comprobado ──┘   └─ comprobado ─┘   └─ necesita el CSCA ─┘
enum VeredictoAutenticidad: Equatable {
    /// Datos íntegros y firma que encadena hasta el CSCA de la JCE.
    case genuina
    /// Datos íntegros y firma estructuralmente válida, pero sin CSCA para probar el emisor.
    case integraSinAnclar
    /// Hay un CSCA cargado pero el firmante no encadena con él (raíz equivocada o antigua).
    case emisorNoReconocido
    /// Algún grupo no cuadra con su hash en el SOD.
    case manipulada
    /// No se pudo evaluar (sin SOD, error de lectura…).
    case sinVerificar

    var titulo: String {
        switch self {
        case .genuina:            return "Documento genuino"
        case .integraSinAnclar:   return "Íntegro · falta anclar al emisor"
        case .emisorNoReconocido: return "Emisor no reconocido"
        case .manipulada:         return "Datos manipulados"
        case .sinVerificar:       return "Sin verificar"
        }
    }

    var detalle: String {
        switch self {
        case .genuina:
            return "Los datos no fueron alterados y la firma encadena hasta el certificado raíz de la JCE."
        case .integraSinAnclar:
            return "Los datos no fueron alterados y la firma es válida, pero falta el certificado raíz (CSCA) de la JCE para probar que el emisor es legítimo. Impórtalo abajo para cerrar la verificación."
        case .emisorNoReconocido:
            return "Los datos están íntegros, pero el firmante no encadena con el CSCA cargado. Puede ser un CSCA equivocado o de otra emisión."
        case .manipulada:
            return "Al menos un grupo de datos no coincide con su huella firmada. El documento no es de fiar."
        case .sinVerificar:
            return "No se pudo evaluar la autenticidad."
        }
    }

    /// Nivel semántico para pintar el veredicto (no es el acento de la app).
    var nivel: NivelSeguridad {
        switch self {
        case .genuina:            return .ok
        case .integraSinAnclar:   return .aviso
        case .emisorNoReconocido: return .aviso
        case .manipulada:         return .critico
        case .sinVerificar:       return .neutro
        }
    }

    var simbolo: String {
        switch self {
        case .genuina:            return "checkmark.seal.fill"
        case .integraSinAnclar:   return "seal"
        case .emisorNoReconocido: return "exclamationmark.triangle.fill"
        case .manipulada:         return "xmark.seal.fill"
        case .sinVerificar:       return "questionmark.circle"
        }
    }
}

enum NivelSeguridad { case ok, aviso, critico, neutro
    var color: Color {
        switch self {
        case .ok:      return .green
        case .aviso:   return .orange
        case .critico: return .red
        case .neutro:  return .secondary
        }
    }
}

/// Resultado detallado, eslabón por eslabón.
struct ResultadoAuth {
    var integridad: Bool          // datos → SOD (hashes)
    var firmaAncladaCSCA: Bool    // DSC → CSCA (necesita el PEM)
    var habiaCSCA: Bool
    var veredicto: VeredictoAutenticidad
}

enum AutenticidadPasiva {

    /// Nombre del PEM del CSCA dentro del contenedor de la app.
    static let nombreCSCA = "csca-jce.pem"

    static var urlCSCA: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let u = docs.appendingPathComponent(nombreCSCA)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static var hayCSCA: Bool { urlCSCA != nil }

    /// Corre la verificación sobre un modelo ya leído. La librería fija sus banderas
    /// (`passportDataNotTampered`, `passportCorrectlySigned`); nosotros las traducimos.
    static func verificar(_ documento: NFCPassportModel) -> ResultadoAuth {
        let csca = urlCSCA
        documento.verifyPassport(masterListURL: csca)

        let integridad = documento.passportDataNotTampered
        let anclada = documento.passportCorrectlySigned
        let habiaCSCA = csca != nil

        let veredicto: VeredictoAutenticidad
        if !integridad {
            veredicto = .manipulada
        } else if anclada {
            veredicto = .genuina
        } else if habiaCSCA {
            veredicto = .emisorNoReconocido
        } else {
            veredicto = .integraSinAnclar
        }
        return ResultadoAuth(integridad: integridad,
                             firmaAncladaCSCA: anclada,
                             habiaCSCA: habiaCSCA,
                             veredicto: veredicto)
    }

    /// Copia un PEM al hueco del CSCA. Acepta un fichero elegido por el usuario.
    @discardableResult
    static func importarCSCA(desde origen: URL) -> Bool {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return false }
        let destino = docs.appendingPathComponent(nombreCSCA)
        let conAcceso = origen.startAccessingSecurityScopedResource()
        defer { if conAcceso { origen.stopAccessingSecurityScopedResource() } }
        guard let datos = try? Data(contentsOf: origen), !datos.isEmpty else { return false }
        // Comprobación mínima de que es un PEM de certificado.
        guard let texto = String(data: datos, encoding: .utf8),
              texto.contains("BEGIN CERTIFICATE") else { return false }
        return (try? datos.write(to: destino)) != nil
    }

    static func borrarCSCA() {
        if let u = urlCSCA { try? FileManager.default.removeItem(at: u) }
    }
}
