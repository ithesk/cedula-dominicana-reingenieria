import Foundation
import CoreNFC

/// Sonda de APDUs crudos, al margen de NFCPassportReader.
///
/// Sirve para mapear qué hay en el chip además del applet eMRTD: ficheros del MF y, sobre
/// todo, el **EF.DIR**, que es el catálogo de aplicaciones de la tarjeta.
///
/// Restricción de iOS que condiciona todo esto: solo se puede hacer `SELECT` por AID de
/// los identificadores declarados en `iso7816.select-identifiers` del Info.plist. Por eso
/// esta pasada selecciona **por identificador de fichero** (`P1=0x00/0x02`), que no está
/// sujeto a esa lista, y se limita a *descubrir* los AID. Seleccionarlos es la pasada 2.
///
/// Nada de lo que hay aquí toca contadores de PIN ni escribe en la tarjeta: todo son
/// SELECT y READ BINARY.
@MainActor
final class ExploradorChip: NSObject, ObservableObject {

    @Published private(set) var bitacora: [String] = []
    @Published private(set) var explorando = false
    /// AID encontrados en el EF.DIR, listos para declarar en el Info.plist.
    @Published private(set) var aidEncontrados: [String] = []

    /// Referencia (P2) del PIN de CitizenID, descubierta SIN consumir intentos.
    @Published private(set) var refPIN: UInt8?
    /// Intentos restantes antes del bloqueo (leídos del `63 CX`), sin descontar ninguno.
    @Published private(set) var intentosRestantes: Int?

    private var sesion: NFCTagReaderSession?

    /// Qué hace la sesión NFC en curso. Separar el modo evita que un botón dispare por
    /// error otra operación distinta.
    private enum Modo { case explorar, reconocer, sscd }
    private var modo: Modo = .explorar

    /// Ficheros estándar que merece la pena tantear en el MF.
    private static let ficheros: [(nombre: String, fid: [UInt8], nota: String)] = [
        ("EF.DIR",          [0x2F, 0x00], "catálogo de aplicaciones"),
        ("EF.ATR/INFO",     [0x2F, 0x01], "parámetros de la tarjeta"),
        ("EF.CardAccess",   [0x01, 0x1C], "parámetros PACE"),
        ("EF.CardSecurity", [0x01, 0x1D], "datos firmados para PACE-CAM"),
    ]

    func limpiar() {
        bitacora = []
        aidEncontrados = []
        refPIN = nil
        intentosRestantes = nil
    }

    func explorar() {
        arrancar(modo: .explorar, mensaje: "Acerca la cédula para explorar el chip.")
    }

    /// Reconocimiento del PIN de CitizenID **sin gastar intentos**: cuántos quedan y qué
    /// referencia usa. No envía ningún PIN.
    func reconocerPIN() {
        arrancar(modo: .reconocer, mensaje: "Acerca la cédula para reconocer el PIN (no se consumen intentos).")
    }

    /// Interroga el applet SSCD por comandos `GET DATA` (solo lectura: no firma, no toca
    /// contadores, no modifica estado).
    func interrogarSSCD() {
        arrancar(modo: .sscd, mensaje: "Acerca la cédula para interrogar el applet de firma (SSCD).")
    }


    private func arrancar(modo: Modo, mensaje: String) {
        guard NFCTagReaderSession.readingAvailable else {
            anotar("❌ Este dispositivo no puede leer etiquetas NFC.")
            return
        }
        limpiar()
        self.modo = modo
        explorando = true
        sesion = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: nil)
        sesion?.alertMessage = mensaje
        sesion?.begin()
    }

    fileprivate func anotar(_ linea: String) {
        bitacora.append(linea)
    }

    /// Vuelca la salida a `Documents/exploracion.txt`. Sin esto la exploración solo existe
    /// en la pantalla y no hay forma de sacarla del iPhone para analizarla.
    fileprivate func guardar() {
        guard let documentos = FileManager.default.urls(for: .documentDirectory,
                                                        in: .userDomainMask).first else { return }
        let destino = documentos.appendingPathComponent("exploracion.txt")
        let sello = ISO8601DateFormatter().string(from: Date())
        let bloque = "\n===== \(sello) · exploración =====\n"
            + bitacora.joined(separator: "\n") + "\n"

        guard let datos = bloque.data(using: .utf8) else { return }
        if let manejador = try? FileHandle(forWritingTo: destino) {
            defer { try? manejador.close() }
            _ = try? manejador.seekToEnd()
            try? manejador.write(contentsOf: datos)
        } else {
            try? datos.write(to: destino)
        }
        anotar("💾 Guardado en exploracion.txt")
    }

    // MARK: - Secuencia de exploración

    fileprivate func recorrer(_ tag: NFCISO7816Tag) async {
        if let historicos = tag.historicalBytes {
            let bytes = [UInt8](historicos)
            anotar("Bytes históricos (≈ATR): \(hex(bytes))")
            // La cédula dominicana se autoidentifica aquí en ASCII ("DomIDv1"), lo que
            // permite reconocerla antes de autenticar nada.
            if let texto = imprimible(bytes) {
                anotar("  → como texto: \(texto)")
            }
        }
        if let aplicacion = tag.applicationData {
            anotar("Application data: \(hex([UInt8](aplicacion)))")
        }
        anotar("")

        // Volver al MF antes de nada.
        let mf = await enviar(tag, clase: 0x00, ins: 0xA4, p1: 0x00, p2: 0x0C,
                              datos: Data([0x3F, 0x00]), etiqueta: "SELECT MF (3F00)")
        guard mf != nil else { return }

        for fichero in Self.ficheros {
            await leerFichero(tag, nombre: fichero.nombre, fid: fichero.fid, nota: fichero.nota)
        }

        await recorrerApplets(tag)
    }

    /// Applets que la propia tarjeta declara en su EF.DIR. Están todos en el Info.plist,
    /// que es requisito de iOS para poder seleccionarlos.
    private static let applets: [(nombre: String, aid: [UInt8])] = [
        ("ICAO (eMRTD)", [0xA0, 0x00, 0x00, 0x02, 0x47, 0x10, 0x01]),
        ("DomRepEID",    [0xD2, 0x76, 0x00, 0x00, 0x98, 0x44, 0x6F, 0x6D, 0x49, 0x44]),
        ("CitizenID",    [0xD2, 0x76, 0x00, 0x00, 0x98, 0x43, 0x69, 0x74, 0x69, 0x7A, 0x65, 0x6E, 0x49, 0x44]),
        ("SSCD",         [0xA0, 0x00, 0x00, 0x00, 0x63, 0x53, 0x53, 0x43, 0x44]),
        ("ePKI (PKCS#15)", [0xA0, 0x00, 0x00, 0x00, 0x63, 0x50, 0x4B, 0x43, 0x53, 0x2D, 0x31, 0x35]),
    ]

    /// Qué significa cada tag del EF.ODF de PKCS#15.
    private static func tipoPKCS15(_ tag: UInt8) -> String {
        switch tag {
        case 0xA0: return "claves privadas"
        case 0xA1: return "claves públicas"
        case 0xA2: return "claves públicas de confianza"
        case 0xA3: return "claves secretas"
        case 0xA4: return "CERTIFICADOS"
        case 0xA5: return "certificados de confianza"
        case 0xA6: return "certificados auxiliares"
        case 0xA7: return "objetos de datos"
        case 0xA8: return "objetos de autenticación (política del PIN)"
        default:   return "desconocido"
        }
    }

    private func recorrerApplets(_ tag: NFCISO7816Tag) async {
        anotar("═══ SELECT por AID ═══")
        for applet in Self.applets {
            let respuesta = await enviar(tag, clase: 0x00, ins: 0xA4, p1: 0x04, p2: 0x00,
                                         datos: Data(applet.aid), le: 256,
                                         etiqueta: "SELECT \(applet.nombre)")
            guard let respuesta, respuesta.traeDatos else { anotar(""); continue }

            if !respuesta.datos.isEmpty {
                anotar("  FCI: \(hex([UInt8](respuesta.datos)))")
                interpretarFCI([UInt8](respuesta.datos))
            }

            // Dentro del applet PKCS#15: leer el ODF y **seguir sus rutas**, en vez de
            // adivinar identificadores de fichero.
            if applet.nombre.hasPrefix("ePKI") {
                await recorrerPKCS15(tag)
            }

            // CitizenID y SSCD están operativos pero no publican catálogo: hay que
            // tantear. Lista dirigida, no fuerza bruta.
            if applet.nombre == "CitizenID" || applet.nombre == "SSCD" {
                await sondear(tag, applet: applet.nombre)
            }
            anotar("")
        }
    }

    private func leerFichero(_ tag: NFCISO7816Tag, nombre: String, fid: [UInt8], nota: String) async {
        anotar("── \(nombre) · \(nota)")

        guard let seleccion = await enviar(tag, clase: 0x00, ins: 0xA4, p1: 0x02, p2: 0x0C,
                                           datos: Data(fid), etiqueta: "  SELECT \(nombre)"),
              seleccion.ok else {
            anotar("")
            return
        }

        var lectura = await enviar(tag, clase: 0x00, ins: 0xB0, p1: 0x00, p2: 0x00,
                                   datos: nil, le: 256, etiqueta: "  READ BINARY")

        // `6C xx` significa "la longitud correcta es xx": se reintenta con ella.
        if let r = lectura, r.sw1 == 0x6C, r.sw2 > 0 {
            lectura = await enviar(tag, clase: 0x00, ins: 0xB0, p1: 0x00, p2: 0x00,
                                   datos: nil, le: Int(r.sw2),
                                   etiqueta: "  READ BINARY (Le=\(r.sw2))")
        }

        guard let lectura, lectura.traeDatos, !lectura.datos.isEmpty else {
            anotar("")
            return
        }

        anotar("  \(lectura.datos.count) bytes: \(hex([UInt8](lectura.datos)))")
        if let texto = imprimible([UInt8](lectura.datos)) {
            anotar("  texto: \(texto)")
        }
        if nombre == "EF.DIR" {
            extraerAID([UInt8](lectura.datos))
        }
        anotar("")
    }

    /// El EF.DIR es una ristra de plantillas `61 LL ...`, y dentro el AID va en el tag `4F`
    /// y la etiqueta legible en el `50`.
    private func extraerAID(_ datos: [UInt8]) {
        var i = 0
        while i + 1 < datos.count {
            let tag = datos[i]
            let longitud = Int(datos[i + 1])
            let inicio = i + 2
            let fin = min(inicio + longitud, datos.count)
            guard inicio <= fin else { break }
            let valor = Array(datos[inicio..<fin])

            switch tag {
            case 0x61:
                extraerAID(valor)          // plantilla de aplicación: recursión
            case 0x4F:
                let aid = hex(valor).replacingOccurrences(of: " ", with: "")
                if !aid.isEmpty, !aidEncontrados.contains(aid) {
                    aidEncontrados.append(aid)
                    anotar("  🔑 AID: \(aid)")
                }
            case 0x50:
                if let etiqueta = String(bytes: valor, encoding: .utf8) {
                    anotar("  etiqueta: \(etiqueta)")
                }
            default:
                break
            }
            i = fin
            if longitud == 0 { i += 1 }
        }
    }

    /// Identificadores a tantear dentro de un applet que no publica catálogo.
    /// Son los estándar de PKCS#15, el rango `44xx` observado en ePKI, y los `01xx`
    /// habituales en tarjetas de identidad. Lista dirigida: barrer los 65.536 posibles
    /// llevaría veinte minutos con la cédula pegada al teléfono.
    private static let fidsASondear: [[UInt8]] = [
        [0x50, 0x31], [0x50, 0x32], [0x50, 0x33], [0x50, 0x34], [0x50, 0x35], [0x50, 0x36],
        [0x44, 0x00], [0x44, 0x01], [0x44, 0x02], [0x44, 0x03], [0x44, 0x04],
        [0x44, 0x05], [0x44, 0x06], [0x44, 0x07], [0x44, 0x08],
        [0x01, 0x01], [0x01, 0x02], [0x01, 0x03], [0x01, 0x04], [0x01, 0x05],
        [0x2F, 0x00], [0x2F, 0x01], [0x00, 0x01], [0x00, 0x02],
    ]

    /// Tantea ficheros dentro del applet ya seleccionado y resume qué encontró.
    private func sondear(_ tag: NFCISO7816Tag, applet: String) async {
        anotar("  Sondeando ficheros de \(applet)…")

        var accesibles: [String] = []
        var protegidos: [String] = []
        var ausentes = 0

        for fid in Self.fidsASondear {
            let nombre = hex(fid)
            let apdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4,
                                      p1Parameter: 0x02, p2Parameter: 0x0C,
                                      data: Data(fid), expectedResponseLength: -1)
            guard let (_, sw1, sw2) = try? await tag.sendCommand(apdu: apdu) else { continue }

            if sw1 == 0x90 && sw2 == 0x00 {
                accesibles.append(nombre)
            } else if sw1 == 0x69 {                    // 6982/6985: existe pero protegido
                protegidos.append(String(format: "%@(%02X%02X)", nombre, sw1, sw2))
            } else {
                ausentes += 1                          // 6A82: no existe
            }
        }

        anotar("  accesibles: \(accesibles.isEmpty ? "ninguno" : accesibles.joined(separator: " "))")
        anotar("  existen pero protegidos: \(protegidos.isEmpty ? "ninguno" : protegidos.joined(separator: " "))")
        anotar("  no existen: \(ausentes) de \(Self.fidsASondear.count)")

        // De los accesibles, volcar el contenido.
        for nombre in accesibles {
            let fid = [UInt8(nombre.prefix(2), radix: 16) ?? 0, UInt8(nombre.suffix(2), radix: 16) ?? 0]
            await leerFichero(tag, nombre: "  EF \(nombre)", fid: fid, nota: "en \(applet)")
        }
    }

    /// Reconoce el PIN de CitizenID sin descontar intentos.
    ///
    /// Se apoya en dos comportamientos estándar de ISO 7816-4, ambos NO consumen intento:
    ///  - `VERIFY` con cuerpo vacío devuelve el contador en `63 CX` (X = intentos que
    ///    quedan), sin verificar nada.
    ///  - `VERIFY` a una referencia (P2) que no existe devuelve `6A88`/`6A86`, sin tocar
    ///    ningún contador.
    /// Probando un puñado de referencias P2 con cuerpo vacío se descubre cuál es el PIN y
    /// en qué estado está, sin arriesgar el bloqueo.
    private func reconocer(_ tag: NFCISO7816Tag) async {
        anotar("── Reconocimiento del PIN de CitizenID (cuerpo vacío, no consume intentos)")

        // SELECT del applet CitizenID por AID.
        let aid: [UInt8] = [0xD2, 0x76, 0x00, 0x00, 0x98, 0x43, 0x69, 0x74, 0x69, 0x7A, 0x65, 0x6E, 0x49, 0x44]
        guard let sel = await enviar(tag, clase: 0x00, ins: 0xA4, p1: 0x04, p2: 0x00,
                                     datos: Data(aid), le: 256, etiqueta: "SELECT CitizenID"),
              sel.traeDatos else {
            anotar("No se pudo seleccionar CitizenID.")
            return
        }

        // Referencias P2 habituales de un PIN de titular. VERIFY (INS 0x20) con Lc=0.
        let referencias: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x10, 0x11, 0x81, 0x82, 0x83]
        for p2 in referencias {
            let apdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0x20,
                                      p1Parameter: 0x00, p2Parameter: p2,
                                      data: Data(), expectedResponseLength: -1)
            guard let (_, sw1, sw2) = try? await tag.sendCommand(apdu: apdu) else { continue }
            let ref = String(format: "%02X", p2)

            if sw1 == 0x63 && (sw2 & 0xF0) == 0xC0 {
                let quedan = Int(sw2 & 0x0F)
                refPIN = p2
                intentosRestantes = quedan
                anotar("  ✅ PIN en referencia \(ref): quedan \(quedan) intentos (\(String(format: "%02X%02X", sw1, sw2)))")
            } else if sw1 == 0x90 && sw2 == 0x00 {
                refPIN = p2
                anotar("  ✅ referencia \(ref): ya verificado en esta sesión (9000)")
            } else if sw1 == 0x69 && sw2 == 0x83 {
                refPIN = p2
                intentosRestantes = 0
                anotar("  ⛔ referencia \(ref): PIN BLOQUEADO (6983) — haría falta el PUK")
            } else if sw1 == 0x69 && sw2 == 0x84 {
                anotar("  referencia \(ref): dato de referencia inválido (6984)")
            } else if sw1 == 0x6A && (sw2 == 0x88 || sw2 == 0x86) {
                // Referencia inexistente: es lo esperado en las que no son el PIN. Silencio.
                continue
            } else {
                anotar("  referencia \(ref): \(String(format: "%02X%02X", sw1, sw2))")
            }
        }

        if refPIN == nil {
            anotar("  No se encontró ninguna referencia de PIN en la lista probada.")
        }
    }

    /// Objetos de datos a pedir con GET DATA. Todos son lecturas: la peor respuesta es
    /// "no lo tengo" (`6A88`), ninguna modifica la tarjeta.
    private static let objetosGetData: [(tag: [UInt8], nombre: String)] = [
        ([0x9F, 0x7F], "CPLC · ciclo de vida de fabricación (chip, fábrica, fecha)"),
        ([0x00, 0x66], "Card Data (ISO)"),
        ([0x7F, 0x66], "capacidades de la tarjeta"),
        ([0x00, 0x67], "Card Capabilities"),
        ([0x01, 0x01], "info propietaria 0101"),
        ([0x01, 0x02], "info propietaria 0102"),
        ([0x00, 0xC4], "info de clave / EF.KeyInfo"),
        ([0xDF, 0x30], "propietario DF30"),
        ([0x9F, 0x70], "estado de ciclo de vida"),
    ]

    /// Interroga el SSCD por comandos, sin firmar nada.
    private func interrogarSSCD(_ tag: NFCISO7816Tag) async {
        anotar("── SSCD por comandos (GET DATA · solo lectura)")

        let aid: [UInt8] = [0xA0, 0x00, 0x00, 0x00, 0x63, 0x53, 0x53, 0x43, 0x44]
        guard let sel = await enviar(tag, clase: 0x00, ins: 0xA4, p1: 0x04, p2: 0x00,
                                     datos: Data(aid), le: 256, etiqueta: "SELECT SSCD"),
              sel.traeDatos else {
            anotar("No se pudo seleccionar SSCD.")
            return
        }
        if !sel.datos.isEmpty { interpretarFCI([UInt8](sel.datos)) }

        anotar("  Consultando objetos de datos (cada uno deja rastro, exista o no):")
        for objeto in Self.objetosGetData {
            // GET DATA: CLA 00, INS CA, P1P2 = el tag del objeto pedido.
            let apdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xCA,
                                      p1Parameter: objeto.tag[0], p2Parameter: objeto.tag[1],
                                      data: Data(), expectedResponseLength: 256)
            let etiqueta = hex(objeto.tag)

            // Registrar SIEMPRE el resultado, incluido "no existe" y "sin contacto":
            // así el silencio nunca se confunde con un hallazgo.
            guard let (datos, sw1, sw2) = try? await tag.sendCommand(apdu: apdu) else {
                anotar("  ⚠️ \(etiqueta) → SIN RESPUESTA (contacto perdido)")
                continue
            }
            let sw = String(format: "%02X%02X", sw1, sw2)

            if sw1 == 0x90 && sw2 == 0x00 && !datos.isEmpty {
                anotar("  ✅ \(etiqueta) \(objeto.nombre)")
                anotar("     \(hex([UInt8](datos)))")
                if let texto = imprimible([UInt8](datos)) { anotar("     texto: \(texto)") }
                if etiqueta == "9F7F" { interpretarCPLC([UInt8](datos)) }
            } else if sw1 == 0x6A && (sw2 == 0x88 || sw2 == 0x86 || sw2 == 0x81) {
                anotar("  ·  \(etiqueta) → \(sw) (no soportado)")
            } else if sw1 == 0x69 {
                anotar("  🔒 \(etiqueta) \(objeto.nombre) → protegido (\(sw))")
            } else {
                anotar("  \(etiqueta) → \(sw)")
            }
        }
        anotar("  (fin de la interrogación SSCD)")
    }

    /// El CPLC (Card Production Life Cycle) trae, en posiciones fijas, quién fabricó el
    /// chip y cuándo. Es el dato de trazabilidad más jugoso, y es público.
    private func interpretarCPLC(_ d: [UInt8]) {
        // El objeto suele venir envuelto en `9F7F 2A ...`; quedarse con los 42 bytes.
        var b = d
        if b.count > 2, b[0] == 0x9F, b[1] == 0x7F { b = Array(b.dropFirst(3)) }
        guard b.count >= 4 else { return }
        let icFabricante = (UInt16(b[0]) << 8) | UInt16(b[1])
        let icTipo = (UInt16(b[2]) << 8) | UInt16(b[3])
        anotar("     → fabricante del IC: \(String(format: "%04X", icFabricante)), tipo: \(String(format: "%04X", icTipo))")
        let fabricantes: [UInt16: String] = [
            0x4790: "NXP", 0x4090: "Infineon", 0x0005: "Infineon",
            0x0007: "NXP", 0x0016: "Samsung", 0x4180: "Atmel/Microchip",
        ]
        if let nombre = fabricantes[icFabricante] {
            anotar("     → probable fabricante: \(nombre)")
        }
    }

    /// Lee el EF.ODF (`5031`) y recorre cada ruta que declara.
    private func recorrerPKCS15(_ tag: NFCISO7816Tag) async {
        guard let odf = await leerContenido(tag, fid: [0x50, 0x31], nombre: "  EF.ODF") else { return }

        // Entradas `Ax LL 30 04 04 02 <fid>`: el tipo va en el tag y la ruta dentro.
        var rutas: [(tag: UInt8, fid: [UInt8])] = []
        var i = 0
        while i + 1 < odf.count {
            let etiqueta = odf[i]
            let longitud = Int(odf[i + 1])
            let fin = min(i + 2 + longitud, odf.count)
            if (0xA0...0xA8).contains(etiqueta), fin - (i + 2) >= 6 {
                let cuerpo = Array(odf[(i + 2)..<fin])
                // Estructura: `30 LL 04 02 <fid>` — un SEQUENCE con el OCTET STRING de la
                // ruta dentro. Hay que entrar en el SEQUENCE: el `04` que va justo detrás
                // del `30` es su LONGITUD, no la etiqueta del OCTET STRING.
                if cuerpo.count >= 6, cuerpo[0] == 0x30 {
                    let interior = Array(cuerpo.dropFirst(2))
                    if interior.count >= 4, interior[0] == 0x04, interior[1] == 0x02 {
                        rutas.append((etiqueta, [interior[2], interior[3]]))
                    }
                }
            }
            i = fin
            if longitud == 0 { i += 1 }
        }

        anotar("  El ODF declara \(rutas.count) ficheros:")
        for ruta in rutas {
            let nombre = String(format: "  EF %02X%02X · %@",
                                ruta.fid[0], ruta.fid[1], Self.tipoPKCS15(ruta.tag))
            await leerFichero(tag, nombre: nombre, fid: ruta.fid, nota: "vía ODF")
        }
    }

    /// Selecciona un fichero y devuelve su contenido, sin escribir el volcado completo.
    private func leerContenido(_ tag: NFCISO7816Tag, fid: [UInt8], nombre: String) async -> [UInt8]? {
        guard let seleccion = await enviar(tag, clase: 0x00, ins: 0xA4, p1: 0x02, p2: 0x0C,
                                           datos: Data(fid), etiqueta: "\(nombre) SELECT"),
              seleccion.ok else { return nil }
        guard let lectura = await enviar(tag, clase: 0x00, ins: 0xB0, p1: 0x00, p2: 0x00,
                                         datos: nil, le: 256, etiqueta: "\(nombre) READ"),
              lectura.traeDatos, !lectura.datos.isEmpty else { return nil }
        return [UInt8](lectura.datos)
    }

    /// Saca del FCI lo que de verdad interesa: identificador de fichero y ciclo de vida.
    private func interpretarFCI(_ datos: [UInt8]) {
        var i = 0
        while i + 1 < datos.count {
            let tag = datos[i]
            let longitud = Int(datos[i + 1])
            let inicio = i + 2
            let fin = min(inicio + longitud, datos.count)
            guard inicio <= fin else { break }
            let valor = Array(datos[inicio..<fin])

            switch tag {
            case 0x6F:
                interpretarFCI(valor)          // plantilla FCI: entrar dentro
                return
            case 0x83:
                anotar("  identificador de fichero: \(hex(valor))")
            case 0x8A:
                let estado = valor.first ?? 0
                let texto: String
                switch estado {
                case 0x01: texto = "creación"
                case 0x03: texto = "⚠️ INICIALIZACIÓN (aún no operativo)"
                case 0x04: texto = "operativo, desactivado"
                case 0x05: texto = "operativo, activado"
                case 0x0C: texto = "terminado"
                default:   texto = "desconocido (\(estado))"
                }
                anotar("  ciclo de vida: \(texto)")
            default:
                break
            }
            i = fin
            if longitud == 0 { i += 1 }
        }
    }

    // MARK: - Envío de APDUs

    private struct Respuesta {
        let datos: Data
        let sw1: UInt8
        let sw2: UInt8

        var ok: Bool { sw1 == 0x90 && sw2 == 0x00 }

        /// `62xx` y `63xx` son **avisos**, no errores: la tarjeta devuelve los datos igual.
        /// El caso típico aquí es `6282` — "fin de fichero antes de leer los N bytes
        /// pedidos" — que sale siempre que se pide más de lo que el fichero mide.
        var traeDatos: Bool { ok || sw1 == 0x62 || sw1 == 0x63 }
    }

    private func enviar(_ tag: NFCISO7816Tag,
                        clase: UInt8, ins: UInt8, p1: UInt8, p2: UInt8,
                        datos: Data? = nil, le: Int = -1,
                        etiqueta: String) async -> Respuesta? {
        let apdu = NFCISO7816APDU(instructionClass: clase,
                                  instructionCode: ins,
                                  p1Parameter: p1,
                                  p2Parameter: p2,
                                  data: datos ?? Data(),
                                  expectedResponseLength: le)
        do {
            let (respuesta, sw1, sw2) = try await tag.sendCommand(apdu: apdu)
            let estado = String(format: "%02X%02X", sw1, sw2)
            anotar("\(etiqueta) → \(estado) \(explicarSW(sw1, sw2))")
            return Respuesta(datos: respuesta, sw1: sw1, sw2: sw2)
        } catch {
            anotar("\(etiqueta) → error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Traducción de los códigos de estado que salen en esta exploración.
    private func explicarSW(_ sw1: UInt8, _ sw2: UInt8) -> String {
        switch (sw1, sw2) {
        case (0x90, 0x00): return "✅"
        case (0x6A, 0x82): return "(fichero no encontrado)"
        case (0x6A, 0x86): return "(parámetros P1/P2 incorrectos)"
        case (0x69, 0x82): return "(condiciones de seguridad no satisfechas)"
        case (0x69, 0x85): return "(condiciones de uso no satisfechas)"
        case (0x6D, 0x00): return "(instrucción no soportada)"
        case (0x6E, 0x00): return "(clase no soportada)"
        case (0x62, 0x82): return "⚠️ aviso: fin de fichero — los datos SÍ vienen"
        case (0x62, _):    return "⚠️ aviso, con datos"
        case (0x6C, _):    return "(longitud correcta: \(sw2))"
        case (0x63, _) where sw2 & 0xF0 == 0xC0:
            return "(quedan \(sw2 & 0x0F) intentos)"
        default: return ""
        }
    }

    // MARK: - Formato

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    private func imprimible(_ bytes: [UInt8]) -> String? {
        let texto = String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return texto.filter { $0 != "." }.count >= 3 ? texto : nil
    }
}

// MARK: - Delegado de la sesión NFC

extension ExploradorChip: NFCTagReaderSessionDelegate {

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            self.explorando = false
            self.sesion = nil
            let texto = "\(error)"
            // Cerrar la hoja tras un final correcto no es un fallo que merezca ruido.
            if !texto.contains("Session invalidated by user")
                && !texto.contains("Success") {
                self.anotar("Sesión terminada: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task { @MainActor in
            guard case let .iso7816(tag) = tags.first else {
                session.invalidate(errorMessage: "La etiqueta no habla ISO7816.")
                self.anotar("❌ Etiqueta detectada, pero no es ISO7816.")
                self.explorando = false
                return
            }

            do {
                try await session.connect(to: tags[0])
            } catch {
                session.invalidate(errorMessage: "No se pudo conectar.")
                self.anotar("❌ Conexión fallida: \(error.localizedDescription)")
                self.explorando = false
                return
            }

            switch self.modo {
            case .explorar:
                self.anotar("Conectado. Explorando…")
                await self.recorrer(tag)
                session.alertMessage = "Exploración terminada."
            case .reconocer:
                self.anotar("Conectado. Reconociendo el PIN…")
                await self.reconocer(tag)
                session.alertMessage = "Reconocimiento terminado."
            case .sscd:
                self.anotar("Conectado. Interrogando el SSCD…")
                await self.interrogarSSCD(tag)
                session.alertMessage = "Interrogación terminada."
            }
            self.guardar()
            session.invalidate()
            self.explorando = false
        }
    }
}
