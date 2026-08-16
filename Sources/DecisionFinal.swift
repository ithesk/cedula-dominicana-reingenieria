import Foundation
import SwiftUI

/// Fase 4 — decisión consolidada + constancia.
///
/// Junta los tres veredictos (genuina · titular · vigencia) en un semáforo único, y genera
/// una constancia **mínima** conforme a la Ley 172-13: sin foto ni biometría, solo la
/// decisión, una referencia enmascarada y el registro de consentimiento.

enum Semaforo {
    case verde, ambar, rojo, gris
    var color: Color {
        switch self { case .verde: return .green; case .ambar: return .orange
                      case .rojo: return .red; case .gris: return .secondary }
    }
    var simbolo: String {
        switch self { case .verde: return "checkmark.circle.fill"; case .ambar: return "exclamationmark.triangle.fill"
                      case .rojo: return "xmark.octagon.fill"; case .gris: return "circle.dashed" }
    }
}

struct EstadoCheck {
    var etiqueta: String
    var estado: Semaforo
    var detalle: String
}

struct DecisionConsolidada {
    var autenticidad: EstadoCheck
    var titular: EstadoCheck
    var vigencia: EstadoCheck
    var global: Semaforo
    var titulo: String
    var resumen: String

    var checks: [EstadoCheck] { [autenticidad, titular, vigencia] }
}

enum MotorDecision {

    static func evaluar(auth: ResultadoAuth?,
                        facial: ResultadoFacial?,
                        fechaExpiracionYYMMDD: String,
                        ahora: Date = Date()) -> DecisionConsolidada {

        let a = evaluarAutenticidad(auth)
        let t = evaluarTitular(facial)
        let v = evaluarVigencia(fechaExpiracionYYMMDD, ahora: ahora)

        // Global: rojo manda; luego ámbar/gris = revisar; todo verde = aprobado.
        let estados = [a.estado, t.estado, v.estado]
        let global: Semaforo
        let titulo: String
        if estados.contains(.rojo) {
            global = .rojo; titulo = "Rechazado"
        } else if estados.contains(.ambar) || estados.contains(.gris) {
            global = .ambar; titulo = "Revisar"
        } else {
            global = .verde; titulo = "Aprobado"
        }

        let resumen: String
        switch global {
        case .verde:  resumen = "Documento genuino, titular verificado y vigente."
        case .ambar:  resumen = "Falta algún paso o no se pudo confirmar del todo. Revisar antes de aceptar."
        case .rojo:   resumen = "Al menos un control falló. No aceptar."
        case .gris:   resumen = "Sin evaluar."
        }
        return DecisionConsolidada(autenticidad: a, titular: t, vigencia: v,
                                   global: global, titulo: titulo, resumen: resumen)
    }

    private static func evaluarAutenticidad(_ auth: ResultadoAuth?) -> EstadoCheck {
        guard let auth else {
            return EstadoCheck(etiqueta: "Genuina", estado: .gris, detalle: "Sin leer.")
        }
        switch auth.veredicto {
        case .genuina:
            return EstadoCheck(etiqueta: "Genuina", estado: .verde, detalle: "Firma encadena al CSCA de la JCE.")
        case .integraSinAnclar:
            return EstadoCheck(etiqueta: "Genuina", estado: .ambar, detalle: "Íntegra, pero falta el CSCA para probar el emisor.")
        case .emisorNoReconocido:
            return EstadoCheck(etiqueta: "Genuina", estado: .rojo, detalle: "El firmante no encadena con el CSCA cargado.")
        case .manipulada:
            return EstadoCheck(etiqueta: "Genuina", estado: .rojo, detalle: "Datos manipulados.")
        case .sinVerificar:
            return EstadoCheck(etiqueta: "Genuina", estado: .gris, detalle: "Sin evaluar.")
        }
    }

    private static func evaluarTitular(_ facial: ResultadoFacial?) -> EstadoCheck {
        guard let f = facial else {
            return EstadoCheck(etiqueta: "Titular", estado: .gris, detalle: "Verificación no realizada.")
        }
        if f.veredicto == .probablesDistintos {
            return EstadoCheck(etiqueta: "Titular", estado: .rojo, detalle: "La cara no coincide con la del chip.")
        }
        let coincide = (f.coincide == true)
        if coincide && f.livenessComprobado {
            return EstadoCheck(etiqueta: "Titular", estado: .verde, detalle: "Cara coincide y persona viva.")
        }
        if coincide && !f.livenessComprobado {
            return EstadoCheck(etiqueta: "Titular", estado: .ambar, detalle: "Cara coincide, pero sin control de vida.")
        }
        return EstadoCheck(etiqueta: "Titular", estado: .ambar, detalle: "Coincidencia no concluyente.")
    }

    /// Vigencia offline a partir de la fecha de expiración de la MRZ. La vigencia «en el
    /// registro» (revocación, estado) necesitaría la API de OGTIC — hueco online no incluido.
    static func evaluarVigencia(_ yymmdd: String, ahora: Date) -> EstadoCheck {
        guard yymmdd.count == 6, let año = Int(yymmdd.prefix(2)),
              let mes = Int(yymmdd.dropFirst(2).prefix(2)), let dia = Int(yymmdd.suffix(2)),
              (1...12).contains(mes), (1...31).contains(dia) else {
            return EstadoCheck(etiqueta: "Vigencia", estado: .gris, detalle: "Fecha de expiración ilegible.")
        }
        var comp = DateComponents()
        comp.year = 2000 + año; comp.month = mes; comp.day = dia
        let cal = Calendar(identifier: .gregorian)
        guard let expira = cal.date(from: comp) else {
            return EstadoCheck(etiqueta: "Vigencia", estado: .gris, detalle: "Fecha inválida.")
        }
        let fmt = DateFormatter(); fmt.dateFormat = "dd/MM/yyyy"
        if expira >= ahora {
            return EstadoCheck(etiqueta: "Vigencia", estado: .verde,
                               detalle: "Vigente hasta \(fmt.string(from: expira)) (offline; falta consulta al registro).")
        } else {
            return EstadoCheck(etiqueta: "Vigencia", estado: .rojo,
                               detalle: "Caducada el \(fmt.string(from: expira)).")
        }
    }
}

/// Constancia mínima. Sin foto, sin biometría, sin datos personales de más: solo la
/// decisión, una referencia enmascarada, los tres veredictos y el consentimiento.
enum Constancia {

    /// Enmascara la cédula: 224-*****21-3 → conserva oficialía, dos dígitos y control.
    static func enmascarar(_ cedula: String?) -> String {
        guard let c = cedula, c.count >= 5 else { return "—" }
        let digitos = c.filter { $0.isNumber }
        guard digitos.count == 11 else { return "referencia no disponible" }
        let a = digitos.prefix(3)
        let z = digitos.suffix(3)
        return "\(a)-•••••\(z.prefix(2))-\(z.suffix(1))"
    }

    static func generar(_ d: DecisionConsolidada, referencia: String, consentimiento: Bool,
                        ahora: Date = Date()) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"
        func linea(_ c: EstadoCheck) -> String {
            let s: String
            switch c.estado { case .verde: s = "OK"; case .ambar: s = "REVISAR"
                              case .rojo: s = "FALLA"; case .gris: s = "n/d" }
            return "  \(c.etiqueta.padding(toLength: 12, withPad: " ", startingAt: 0)) \(s)"
        }
        return """
        CONSTANCIA DE VERIFICACIÓN DE IDENTIDAD
        ---------------------------------------
        Fecha           : \(fmt.string(from: ahora))
        Referencia      : \(referencia)
        Resultado       : \(d.titulo.uppercased())

        Controles:
        \(linea(d.autenticidad))
        \(linea(d.titular))
        \(linea(d.vigencia))

        Consentimiento del titular: \(consentimiento ? "SÍ" : "NO")

        Conforme a la Ley 172-13: no se conservan foto, biometría ni datos
        personales adicionales. Esta constancia solo registra la decisión.
        """
    }

    @discardableResult
    static func guardar(_ texto: String, ahora: Date = Date()) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let carpeta = docs.appendingPathComponent("constancias")
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = carpeta.appendingPathComponent("constancia-\(fmt.string(from: ahora)).txt")
        return (try? texto.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}
