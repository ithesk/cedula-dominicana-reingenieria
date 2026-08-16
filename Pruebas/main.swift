import Foundation

// Todos los datos de este archivo son INVENTADOS. Reproducen la estructura real de la
// MRZ de la cédula dominicana, pero ni el serial, ni las fechas, ni la cédula, ni los
// nombres corresponden a ninguna persona: los tres campos de la MRZ son, juntos, la
// llave de acceso al chip, y no tienen por qué estar en un repositorio.

var fallos = 0
func comprobar(_ titulo: String, _ obtenido: String?, _ esperado: String?) {
    let ok = obtenido == esperado
    if !ok { fallos += 1 }
    print("\(ok ? "✅" : "❌") \(titulo)")
    if !ok { print("     esperado: \(esperado ?? "nil")\n     obtenido: \(obtenido ?? "nil")") }
}

let doc = "AB01234567"     // serial ficticio de 10, como el dominicano
let nac = "900101"
let exp = "400101"

// --- Dígitos de control (ICAO 9303, pesos 7-3-1) ---
comprobar("dígito del serial de 10", LlaveMRZ.digitoControl(doc), "7")
comprobar("dígito de la fecha de nacimiento", LlaveMRZ.digitoControl(nac), "1")
comprobar("dígito de la fecha de expiración", LlaveMRZ.digitoControl(exp), "6")

// --- Las dos opciones de llave deben ser DISTINTAS ---
let a = LlaveMRZ.construir(documento: doc, nacimiento: nac, expiracion: exp, opcion: .completa)
let b = LlaveMRZ.construir(documento: doc, nacimiento: nac, expiracion: exp, opcion: .truncada)
comprobar("llave opción A", a, "AB01234567" + "7" + nac + "1" + exp + "6")
comprobar("llave opción B", b, "AB0123456"  + "<" + nac + "1" + exp + "6")
comprobar("A y B son distintas", a == b ? "iguales" : "distintas", "distintas")

// --- Reconstrucción del serial de 10 desde la MRZ ---
comprobar("serial reconstruido",
          AnalizadorMRZ.reconstruirDocumento(campo: "AB0123456", digito: "<", opcional: "77<<<<<<<<<<<<<"),
          "AB01234567")
comprobar("serial normal de 9 no se toca",
          AnalizadorMRZ.reconstruirDocumento(campo: "CD1234567", digito: "4", opcional: "<<<<<<<<<<<<<<<"),
          "CD1234567")
comprobar("dígito que no cuadra → no se reconstruye",
          AnalizadorMRZ.reconstruirDocumento(campo: "AB0123456", digito: "<", opcional: "79<<<<<<<<<<<<<"),
          "AB0123456")

// --- Cédula nacional: va en la zona opcional de la LÍNEA 1, tras el resto del serial ---
// Reparto real observado en el chip: "<sobrante><dígito>«<»<11 dígitos>«<»".
comprobar("cédula tras el sobrante del serial",
          AnalizadorMRZ.extraerCedulaNacional("77<00112345678<" + "S<<<<<<<<<<"),
          "001-1234567-8")
comprobar("no confunde el sobrante con la cédula",
          AnalizadorMRZ.extraerCedulaNacional("77<<<<<<<<<<<<<" + "S<<<<<<<<<<"),
          nil)
comprobar("zona vacía → nil", AnalizadorMRZ.extraerCedulaNacional("<<<<<<<<<<<"), nil)

// --- MRZ TD1 completa, con el reparto real de la cédula dominicana ---
let l1 = "IDDOMAB0123456<77<00112345678<"
let l2 = "9001011M4001016DOMS<<<<<<<<<<0"
let l3 = "PEREZ<GOMEZ<<JUAN<CARLOS<<<<<<"
for (nombre, l) in [("L1", l1), ("L2", l2), ("L3", l3)] {
    comprobar("\(nombre) mide 30", String(l.count), "30")
}
if let d = AnalizadorMRZ.analizar(lineas: [l1, l2, l3]) {
    comprobar("MRZ → documento", d.numeroDocumento, "AB01234567")
    comprobar("MRZ → nacimiento", d.fechaNacimiento, nac)
    comprobar("MRZ → expiración", d.fechaExpiracion, exp)
    comprobar("MRZ → cédula", d.cedulaNacional, "001-1234567-8")
    comprobar("MRZ → dígitos cuadran", d.digitosCuadran ? "sí" : "no", "sí")
} else {
    fallos += 1
    print("❌ el parser no reconoció la MRZ sintética")
}

// --- Nombres: se parten por «<<», apellidos primero (así viene en la línea 3) ---
let partes = l3.components(separatedBy: "<<")
func limpiar(_ t: String) -> String {
    t.replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}
comprobar("apellidos desde la MRZ", limpiar(partes.first ?? ""), "PEREZ GOMEZ")
comprobar("nombres desde la MRZ", limpiar(partes.dropFirst().joined(separator: " ")), "JUAN CARLOS")

// --- OCR sucio: espacios y confusiones típicas en las fechas ---
if let d = AnalizadorMRZ.analizar(lineas: ["IDDOM AB0123456< 77<00112345678<",
                                           "9OO1O11M4OO1O16DOMS<<<<<<<<<<0",
                                           l3]) {
    comprobar("OCR sucio → nacimiento", d.fechaNacimiento, nac)
    comprobar("OCR sucio → expiración", d.fechaExpiracion, exp)
    comprobar("OCR sucio → documento", d.numeroDocumento, "AB01234567")
} else {
    fallos += 1
    print("❌ el parser se rindió con la MRZ sucia del OCR")
}

// --- Validación de campos ---
comprobar("fecha mal → error",
          LlaveMRZ.validar(documento: doc, nacimiento: "01/01/90", expiracion: exp) == nil ? "acepta" : "rechaza",
          "rechaza")
comprobar("datos bien → acepta",
          LlaveMRZ.validar(documento: doc, nacimiento: nac, expiracion: exp) == nil ? "acepta" : "rechaza",
          "acepta")

print(fallos == 0 ? "\n🎉 Todas las comprobaciones pasan." : "\n💥 \(fallos) comprobaciones fallan.")
exit(fallos == 0 ? 0 : 1)
