import Foundation

/// Lo que necesitamos de la MRZ para derivar la llave, más algún extra informativo.
struct DatosMRZ {
    var numeroDocumento: String
    var fechaNacimiento: String      // YYMMDD
    var fechaExpiracion: String      // YYMMDD
    var lineas: [String]
    /// Cédula nacional (###-#######-#) si venía en la zona opcional de la línea 2.
    var cedulaNacional: String?
    /// `true` si los dígitos de control de las fechas cuadran; si no, conviene revisar a mano.
    var digitosCuadran: Bool
}

/// Parser de MRZ formato TD1 (3 líneas de 30 caracteres), que es el de la cédula.
///
/// Posiciones (base 0):
/// - Línea 1: `[0..2]` tipo · `[2..5]` país emisor · `[5..14]` nº documento · `[14]` dígito · `[15..30]` opcional
/// - Línea 2: `[0..6]` nacimiento · `[6]` dígito · `[7]` sexo · `[8..14]` expiración · `[14]` dígito ·
///            `[15..18]` nacionalidad · `[18..29]` opcional · `[29]` dígito compuesto
/// - Línea 3: apellidos `<<` nombres
enum AnalizadorMRZ {

    static let longitudLinea = 30

    /// ¿Esta línea suelta del OCR tiene pinta de ser una línea de MRZ?
    static func pareceLineaMRZ(_ texto: String) -> Bool {
        let limpio = normalizar(texto)
        guard (26...34).contains(limpio.count) else { return false }
        guard limpio.contains("<") else { return false }
        // Al menos la mitad de los caracteres deben ser válidos de MRZ.
        let validos = limpio.filter { $0.isUppercase || $0.isNumber || $0 == "<" }.count
        return validos == limpio.count
    }

    /// Quita espacios y ruido típico del OCR, y sube a mayúsculas.
    static func normalizar(_ texto: String) -> String {
        texto.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "«", with: "<")
            .replacingOccurrences(of: "‹", with: "<")
            .replacingOccurrences(of: "K<", with: "<<")   // confusión frecuente en cadenas de relleno
            .filter { $0.isUppercase || $0.isNumber || $0 == "<" }
    }

    /// Ajusta la línea a 30 caracteres exactos (rellena o recorta).
    static func encuadrar(_ linea: String) -> String {
        let limpio = normalizar(linea)
        if limpio.count >= longitudLinea { return String(limpio.prefix(longitudLinea)) }
        return limpio + String(repeating: "<", count: longitudLinea - limpio.count)
    }

    /// Corrige confusiones del OCR en campos que solo pueden ser numéricos.
    static func soloDigitos(_ texto: String) -> String {
        let equivalencias: [Character: Character] = [
            "O": "0", "Q": "0", "D": "0", "U": "0",
            "I": "1", "L": "1", "T": "1",
            "Z": "2", "S": "5", "B": "8", "G": "6", "A": "4", "E": "6"
        ]
        return String(texto.map { equivalencias[$0] ?? $0 })
    }

    static func trozo(_ linea: String, _ rango: Range<Int>) -> String {
        let caracteres = Array(linea)
        guard rango.lowerBound < caracteres.count else { return "" }
        let fin = min(rango.upperBound, caracteres.count)
        return String(caracteres[rango.lowerBound..<fin])
    }

    /// Analiza tres líneas ya reconocidas. Devuelve `nil` si no encajan en TD1.
    static func analizar(lineas crudas: [String]) -> DatosMRZ? {
        guard crudas.count >= 3 else { return nil }
        let l1 = encuadrar(crudas[0])
        let l2 = encuadrar(crudas[1])
        let l3 = encuadrar(crudas[2])

        // La línea 2 es la que tiene estructura reconocible: fechas y sexo.
        let nacimiento = soloDigitos(trozo(l2, 0..<6))
        let expiracion = soloDigitos(trozo(l2, 8..<14))
        guard LlaveMRZ.esFechaYYMMDD(nacimiento), LlaveMRZ.esFechaYYMMDD(expiracion) else { return nil }

        let digitoNacimiento = soloDigitos(trozo(l2, 6..<7))
        let digitoExpiracion = soloDigitos(trozo(l2, 14..<15))
        let cuadran = digitoNacimiento == LlaveMRZ.digitoControl(nacimiento)
                   && digitoExpiracion == LlaveMRZ.digitoControl(expiracion)

        // Número de documento: 9 caracteres + dígito de control en la línea 1.
        let campo = trozo(l1, 5..<14)
        let digito = trozo(l1, 14..<15)
        let opcional1 = trozo(l1, 15..<30)
        let documento = reconstruirDocumento(campo: campo, digito: digito, opcional: opcional1)

        return DatosMRZ(numeroDocumento: documento,
                        fechaNacimiento: nacimiento,
                        fechaExpiracion: expiracion,
                        lineas: [l1, l2, l3],
                        cedulaNacional: extraerCedulaNacional(opcional1 + trozo(l2, 18..<29)),
                        digitosCuadran: cuadran)
    }

    /// Si el dígito de control es el relleno `<`, el serial no cabía en 9: el resto está
    /// al principio de la zona opcional, seguido del dígito de control del número completo.
    static func reconstruirDocumento(campo: String, digito: String, opcional: String) -> String {
        let base = campo.replacingOccurrences(of: "<", with: "")
        guard digito == "<" else { return base }

        let cola = opcional.drop(while: { $0 == "<" })
        let util = String(cola.prefix(while: { $0 != "<" }))
        guard util.count >= 2 else { return base }

        let resto = String(util.dropLast())
        let digitoCompleto = String(util.suffix(1))
        let completo = base + resto
        // Solo lo damos por bueno si el dígito de control del número entero cuadra.
        return LlaveMRZ.digitoControl(completo) == digitoCompleto ? completo : base
    }

    /// La cédula nacional son 11 dígitos sueltos en la zona de datos opcionales.
    ///
    /// Va en la de la **línea 1**, detrás del sobrante del serial. La zona real queda así:
    /// `77<00112345678<` — primero el resto del número de documento (`7`) y el dígito de
    /// control del número completo (`0`), luego un relleno, y después la cédula.
    /// Por eso no vale con juntar todos los dígitos: hay que trocear por `<` y quedarse
    /// con el grupo que mida exactamente 11 cifras.
    ///
    /// Se le pasan las dos zonas opcionales concatenadas, que es como las guarda el DG1.
    static func extraerCedulaNacional(_ opcional: String) -> String? {
        let grupos = opcional
            .split(separator: "<", omittingEmptySubsequences: true)
            .map(String.init)

        guard let cedula = grupos.last(where: { $0.count == 11 && $0.allSatisfy(\.isNumber) })
        else { return nil }

        let a = cedula.prefix(3)
        let b = cedula.dropFirst(3).prefix(7)
        let c = cedula.suffix(1)
        return "\(a)-\(b)-\(c)"
    }
}
