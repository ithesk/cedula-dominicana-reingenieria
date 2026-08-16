import Foundation

/// Cómo se arma el campo "número de documento" de la MRZ al derivar la llave BAC/PACE.
///
/// El serial de la cédula dominicana tiene 10 caracteres (p. ej. `AB01234567`) y el campo
/// de la MRZ TD1 solo admite 9, así que ICAO 9303 obliga a partirlo: los 9 primeros van al
/// campo y el dígito de control se sustituye por el relleno `<`; el resto viaja en la zona
/// de datos opcionales. Las implementaciones no se ponen de acuerdo en cuál de las dos
/// formas se usa para derivar la llave, así que probamos las dos.
enum OpcionLlave: String, CaseIterable, Identifiable {
    /// Opción A (por defecto): se usa el serial completo de 10 caracteres y se le calcula
    /// su dígito de control.
    case completa
    /// Opción B (fallback): se usa el campo tal y como está impreso en la MRZ — 9
    /// caracteres — y el dígito de control es el relleno `<`.
    case truncada

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .completa: return "A · serial completo"
        case .truncada: return "B · 9 + relleno"
        }
    }

    /// Cómo queda el campo de documento con este criterio, para enseñarlo en pantalla.
    func campoDeEjemplo(_ documento: String) -> String {
        LlaveMRZ.campoDocumento(documento, opcion: self).campo
            + LlaveMRZ.campoDocumento(documento, opcion: self).digito
    }
}

/// Construcción de la llave MRZ (la "MRZ information" de ICAO 9303 parte 11) de la que
/// NFCPassportReader deriva las claves de sesión de BAC y PACE.
///
/// Deliberadamente **no** usamos `PassportUtils.getMRZKey` de la librería: esa función
/// rellena y **trunca a 9** el número de documento, con lo que las opciones A y B
/// producirían exactamente la misma llave y el conmutador no serviría de nada.
enum LlaveMRZ {

    /// Dígito de control de ICAO 9303: pesos cíclicos 7-3-1, dígitos por su valor,
    /// letras A-Z como 10-35 y el relleno `<` como 0.
    static func digitoControl(_ cadena: String) -> String {
        let pesos = [7, 3, 1]
        var suma = 0
        for (indice, caracter) in cadena.uppercased().enumerated() {
            let valor: Int
            if caracter.isNumber, let digito = caracter.wholeNumberValue {
                valor = digito
            } else if let ascii = caracter.asciiValue, (65...90).contains(ascii) {
                valor = Int(ascii) - 55
            } else {
                valor = 0 // incluye el relleno '<' y cualquier basura del OCR
            }
            suma += valor * pesos[indice % 3]
        }
        return String(suma % 10)
    }

    /// Rellena por la derecha con `<` hasta la longitud pedida (no recorta si sobra).
    static func rellenar(_ valor: String, hasta longitud: Int) -> String {
        let limpio = valor.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "<" }
        guard limpio.count < longitud else { return limpio }
        return limpio + String(repeating: "<", count: longitud - limpio.count)
    }

    /// Devuelve el campo de documento y su dígito de control según el criterio elegido.
    static func campoDocumento(_ documento: String, opcion: OpcionLlave) -> (campo: String, digito: String) {
        let limpio = documento.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "<" }
        switch opcion {
        case .completa:
            let campo = rellenar(limpio, hasta: 9)   // solo rellena; si mide 10, se respeta
            return (campo, digitoControl(campo))
        case .truncada:
            let campo = String(rellenar(limpio, hasta: 9).prefix(9))
            return (campo, "<")                       // el relleno ocupa el dígito de control
        }
    }

    /// Arma la llave completa: documento + dígito, nacimiento + dígito, expiración + dígito.
    /// Las fechas van en **YYMMDD** (ojo: la cédula las imprime en DD/MM/AAAA).
    static func construir(documento: String,
                          nacimiento: String,
                          expiracion: String,
                          opcion: OpcionLlave) -> String {
        let (campo, digito) = campoDocumento(documento, opcion: opcion)
        let nac = rellenar(nacimiento, hasta: 6)
        let exp = rellenar(expiracion, hasta: 6)
        return campo + digito
            + nac + digitoControl(nac)
            + exp + digitoControl(exp)
    }

    /// Validación mínima de los campos antes de encender la antena, para no gastar un
    /// intento de lectura con datos obviamente mal escritos.
    static func validar(documento: String, nacimiento: String, expiracion: String) -> String? {
        let doc = documento.trimmingCharacters(in: .whitespacesAndNewlines)
        if doc.isEmpty { return "Falta el número de documento." }
        if doc.count > 14 { return "El número de documento es demasiado largo." }
        if !esFechaYYMMDD(nacimiento) { return "La fecha de nacimiento debe ser YYMMDD (p. ej. 900101)." }
        if !esFechaYYMMDD(expiracion) { return "La fecha de expiración debe ser YYMMDD (p. ej. 400101)." }
        return nil
    }

    static func esFechaYYMMDD(_ valor: String) -> Bool {
        guard valor.count == 6, valor.allSatisfy({ $0.isNumber }) else { return false }
        let mes = Int(valor.dropFirst(2).prefix(2)) ?? 0
        let dia = Int(valor.suffix(2)) ?? 0
        return (1...12).contains(mes) && (1...31).contains(dia)
    }
}
