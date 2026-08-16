import Foundation
import SwiftUI
import NFCPassportReader

/// Datos que sacamos del chip en la Fase 1 (DG1 + DG2).
struct DatosCedula {
    var apellidos: String
    var nombres: String
    var numeroDocumento: String
    var nacionalidad: String
    var paisEmisor: String
    var sexo: String
    var fechaNacimiento: String
    var fechaExpiracion: String
    var tipoDocumento: String
    var foto: UIImage?
    var gruposLeidos: [String]
    /// Serial del plástico reconstruido a partir de la MRZ del chip (10 caracteres).
    var serialCompleto: String
    /// Cédula nacional ###-#######-#, que viaja en la zona opcional de la línea 2.
    var cedulaNacional: String?
    /// MRZ tal cual la guarda el chip, útil para diagnosticar.
    var mrzCruda: String?

    // --- DG11: datos personales adicionales ---
    var lugarNacimiento: String?
    var direccion: String?
    var telefono: String?
    var profesion: String?
    var numeroPersonal: String?

    // --- DG12: datos de emisión del documento ---
    var autoridadEmisora: String?
    var fechaEmision: String?
    var observaciones: String?
    var momentoPersonalizacion: String?

    // --- DG7: firma manuscrita ---
    var firma: UIImage?

    // --- DG13: datos nacionales, sin parser en la librería ---
    var dg13Texto: String?
    var dg13Hex: String?

    /// Sellos de seguridad que la librería calcula durante la lectura.
    var seguridad: Seguridad

    var nombreCompleto: String {
        [nombres, apellidos].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Lo que se puede afirmar sobre el chip **sin** tener el CSCA de la JCE.
struct Seguridad {
    /// PACE: canal cifrado establecido con la llave derivada de la MRZ.
    var pace: String
    /// BAC, si se usó como alternativa.
    var bac: String
    /// Chip Authentication: el chip demostró tener la clave privada del DG14.
    /// Descarta el clonado simple (copiar los datos a un chip virgen).
    var chipAutenticado: Bool
    /// Los hashes de los grupos leídos cuadran con los que declara el SOD.
    var sinManipular: Bool
    /// Firma del SOD verificada contra el CSCA. Requiere el certificado de la JCE.
    var firmaVerificada: Bool
    /// Grupos que el SOD declara presentes en el chip.
    var gruposDeclarados: [String]
}

enum EstadoLectura: Equatable {
    case inactivo
    case leyendo
    case ok
    case fallo(String)
}

/// Único punto de contacto con NFCPassportReader. Si la librería cambia de API entre
/// versiones, todo lo que hay que tocar está en este archivo.
@MainActor
final class CedulaReader: ObservableObject {

    @Published private(set) var estado: EstadoLectura = .inactivo
    @Published private(set) var datos: DatosCedula?
    @Published private(set) var bitacora: [String] = []
    /// La llave que se mandó al chip, para poder comparar A vs B a ojo cuando algo falla.
    @Published private(set) var llaveUsada: String = ""
    /// Traza cruda de la librería (APDUs y derivación BAC) del último intento.
    @Published private(set) var traza: [String] = []
    /// Dónde quedó guardada la traza dentro del contenedor de la app.
    @Published private(set) var archivoTraza: URL?
    /// Veredicto de autenticidad (Passive Authentication, Fase 2).
    @Published private(set) var autenticidad: ResultadoAuth?

    /// Último documento leído, para poder reverificar al importar el CSCA sin releer.
    private var ultimoDocumento: NFCPassportModel?

    var hayCSCA: Bool { AutenticidadPasiva.hayCSCA }

    private let lector = PassportReader()

    var leyendo: Bool { estado == .leyendo }

    func limpiar() {
        estado = .inactivo
        datos = nil
        bitacora = []
        llaveUsada = ""
        traza = []
        autenticidad = nil
        ultimoDocumento = nil
    }

#if DEBUG
    /// Carga datos FICTICIOS para capturar pantallas sin cédula ni NFC (solo demo/capturas).
    func cargarDemo() {
        let foto = CedulaReader.imagenDemo()
        datos = DatosCedula(
            apellidos: "PEREZ GOMEZ", nombres: "JUAN CARLOS",
            numeroDocumento: "AB1234567", nacionalidad: "DOM", paisEmisor: "DOM",
            sexo: "M", fechaNacimiento: "900101", fechaExpiracion: "400101",
            tipoDocumento: "I", foto: foto,
            gruposLeidos: ["DG1", "DG2", "DG7", "DG11", "DG12", "DG13", "DG14"],
            serialCompleto: "AB1234567", cedulaNacional: "224-0011223-4",
            mrzCruda: "IDDOMAB1234567<77<22400112234<\n9001011M4001016DOMS<<<<<<<<<<0\nPEREZ<GOMEZ<<JUAN<CARLOS<<<<<<",
            lugarNacimiento: "SANTO DOMINGO, R.D.", direccion: nil, telefono: nil,
            profesion: nil, numeroPersonal: "224-0011223-4",
            autoridadEmisora: "JUNTA CENTRAL ELECTORAL", fechaEmision: "20260812",
            observaciones: nil, momentoPersonalizacion: nil, firma: foto,
            dg13Texto: "NNN-NN-AAAA-NN-NNNNNNNN · 224 · 13449 · 1705 · 00", dg13Hex: "6D405C0A5F11…",
            seguridad: Seguridad(pace: "PACEStatus.success", bac: "notDone",
                                 chipAutenticado: true, sinManipular: true, firmaVerificada: false,
                                 gruposDeclarados: ["DG1", "DG2", "DG3", "DG7", "DG11", "DG12", "DG13", "DG14"]))
        autenticidad = ResultadoAuth(integridad: true, firmaAncladaCSCA: false,
                                     habiaCSCA: false, veredicto: .integraSinAnclar)
        estado = .ok
    }

    static func imagenDemo() -> UIImage {
        let size = CGSize(width: 240, height: 300)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.systemGray4.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let cfg = UIImage.SymbolConfiguration(pointSize: 130)
            UIImage(systemName: "person.fill", withConfiguration: cfg)?
                .withTintColor(.systemGray, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 55, y: 60, width: 130, height: 180))
        }
    }
#endif

    /// Reevalúa la autenticidad del último documento leído — para usar tras importar el CSCA
    /// sin tener que volver a acercar la cédula.
    func reverificarAutenticidad() {
        guard let documento = ultimoDocumento else { return }
        autenticidad = AutenticidadPasiva.verificar(documento)
        datos = convertir(documento)
        anotar("🔁 Reverificado con CSCA: \(autenticidad?.veredicto.titulo ?? "—")")
    }

    private func veredictoEnBitacora() -> String {
        guard let a = autenticidad else { return "" }
        let ancla = a.habiaCSCA ? (a.firmaAncladaCSCA ? "raíz OK" : "raíz no encadena")
                                : "sin CSCA"
        return "🔐 Autenticidad: \(a.veredicto.titulo) · integridad \(a.integridad ? "OK" : "FALLA") · \(ancla)"
    }

    func leer(documento: String,
              nacimiento: String,
              expiracion: String,
              opcion: OpcionLlave) async {

        if let problema = LlaveMRZ.validar(documento: documento,
                                           nacimiento: nacimiento,
                                           expiracion: expiracion) {
            estado = .fallo(problema)
            anotar("⚠️ \(problema)")
            return
        }

        let llave = LlaveMRZ.construir(documento: documento,
                                       nacimiento: nacimiento,
                                       expiracion: expiracion,
                                       opcion: opcion)
        llaveUsada = llave
        datos = nil
        estado = .leyendo
        anotar("Opción \(opcion.titulo) → llave MRZ: \(llave)")
        anotar("Acerca la cédula a la parte superior del reverso del iPhone…")

        let inicio = Date()
        do {
            // Todo lo que el SOD de la cédula declara y no está protegido por EAC.
            // DG3 (huellas) y DG4 los descarta la propia librería con skipSecureElements.
            let documento = try await lector.readPassport(
                mrzKey: llave,
                tags: [.COM, .SOD, .DG1, .DG2, .DG7, .DG11, .DG12, .DG13, .DG14, .DG15],
                customDisplayMessage: mensajeEnPantalla
            )
            ultimoDocumento = documento
            autenticidad = AutenticidadPasiva.verificar(documento)
            datos = convertir(documento)
            volcarGrupos(documento)
            estado = .ok
            anotar(veredictoEnBitacora())
            anotar("✅ Lectura correcta. Grupos leídos: \(datos?.gruposLeidos.joined(separator: ", ") ?? "—")")
            capturarTraza(desde: inicio, cabecera: "opción \(opcion.titulo) · OK")
        } catch {
            let descripcion = explicar(error)
            estado = .fallo(descripcion)
            anotar("❌ \(descripcion)")
            capturarTraza(desde: inicio, cabecera: "opción \(opcion.titulo) · FALLO: \(descripcion)")
        }
    }

    /// Vuelca cada grupo en crudo a `Documents/grupos/`, para poder analizarlos en el Mac
    /// sin gastar más lecturas de la cédula. Es material de investigación, no de producción.
    private func volcarGrupos(_ documento: NFCPassportModel) {
        guard let documentos = FileManager.default.urls(for: .documentDirectory,
                                                        in: .userDomainMask).first else { return }
        let carpeta = documentos.appendingPathComponent("grupos")
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)

        var escritos: [String] = []
        for (id, grupo) in documento.dataGroupsRead where !grupo.data.isEmpty {
            let destino = carpeta.appendingPathComponent("\(id).bin")
            if (try? Data(grupo.data).write(to: destino)) != nil {
                escritos.append("\(id)(\(grupo.data.count)b)")
            }
        }

        // El certificado firmante (DSC) viaja dentro del SOD, que es un CMS SignedData.
        // No se lo pedimos a la librería: `documentSigningCertificate` solo se rellena si
        // se hace Passive Authentication con una master list, que aquí no tenemos.
        // El SOD en crudo ya está volcado; el DER del CMS es lo mismo sin la cabecera TLV
        // `77 <longitud>`, y así se puede abrir directamente con OpenSSL en el Mac:
        //     openssl pkcs7 -inform DER -in SOD.der -print_certs
        if let sod = documento.getDataGroup(.SOD), !sod.data.isEmpty {
            let bytes = sod.data
            var inicio = 1                       // saltar el tag 0x77
            if bytes.count > 1, bytes[1] & 0x80 != 0 {
                inicio += 1 + Int(bytes[1] & 0x7F)   // longitud larga
            } else {
                inicio += 1                          // longitud corta
            }
            if inicio < bytes.count {
                let der = Data(bytes[inicio...])
                try? der.write(to: carpeta.appendingPathComponent("SOD.der"))
                escritos.append("SOD.der")
            }
        }

        anotar("💾 Volcado: \(escritos.sorted().joined(separator: " "))")
    }

    /// Recupera del log del sistema lo que la librería escribió durante este intento.
    private func capturarTraza(desde inicio: Date, cabecera: String) {
        let lineas = Traza.recoger(desde: inicio)
        traza = lineas
        archivoTraza = Traza.guardar(lineas, cabecera: cabecera)
        anotar("📄 Traza: \(lineas.count) líneas → \(Traza.nombreArchivo)")
    }

    // MARK: - Traducción del modelo de la librería

    private func convertir(_ documento: NFCPassportModel) -> DatosCedula {
        let extra = leerZonaOpcional(documento)
        let dg11 = documento.getDataGroup(.DG11) as? DataGroup11
        let dg12 = documento.getDataGroup(.DG12) as? DataGroup12
        let dg13 = leerDG13(documento)

        // El modelo no expone una bandera de Chip Authentication, así que la deducimos:
        // el DG14 trae las claves públicas y la librería reinicia la mensajería segura con
        // AES en cuanto la CA tiene éxito. Si el DG14 se leyó y no hubo error, se hizo.
        let chipAutenticado = documento.getDataGroup(.DG14) != nil
            && documento.isChipAuthenticationSupported

        let nombre = nombresDeMRZ(documento)

        return DatosCedula(
            apellidos: nombre.apellidos,
            nombres: nombre.nombres,
            numeroDocumento: documento.documentNumber,
            nacionalidad: documento.nationality,
            paisEmisor: documento.issuingAuthority,
            sexo: documento.gender,
            fechaNacimiento: documento.dateOfBirth,
            fechaExpiracion: documento.documentExpiryDate,
            tipoDocumento: documento.documentType,
            foto: documento.passportImage,
            gruposLeidos: documento.dataGroupsRead.keys.map { "\($0)" }.sorted(),
            serialCompleto: extra.serial ?? documento.documentNumber,
            cedulaNacional: extra.cedula,
            mrzCruda: extra.mrz,

            lugarNacimiento: dg11?.placeOfBirth,
            direccion: dg11?.address,
            telefono: dg11?.telephone,
            profesion: dg11?.profession,
            numeroPersonal: dg11?.personalNumber ?? documento.personalNumber,

            autoridadEmisora: dg12?.issuingAuthority,
            fechaEmision: dg12?.dateOfIssue,
            observaciones: dg12?.endorsementsOrObservations,
            momentoPersonalizacion: dg12?.personalizationTime,

            firma: imagenDeFirma(documento),

            dg13Texto: dg13.texto,
            dg13Hex: dg13.hex,

            seguridad: Seguridad(
                pace: "\(documento.PACEStatus)",
                bac: "\(documento.BACStatus)",
                chipAutenticado: chipAutenticado,
                sinManipular: documento.passportDataNotTampered,
                firmaVerificada: documento.passportCorrectlySigned,
                gruposDeclarados: documento.dataGroupHashes.keys.map { "\($0)" }.sorted()
            )
        )
    }

    /// Nombre y apellidos **siempre desde la MRZ del DG1**, nunca desde el DG11.
    ///
    /// `documento.lastName` / `.firstName` no valen aquí: en cuanto se lee el DG11, la
    /// librería prefiere su campo `fullName` y lo parte por `<<`. La cédula dominicana lo
    /// guarda como `JUAN<CARLOS<PEREZ<GOMEZ` — nombres primero y **sin** `<<`, así
    /// que el corte no encuentra nada: los apellidos se quedan con el nombre completo en
    /// orden invertido y el nombre acaba vacío.
    ///
    /// La línea 3 de la MRZ sí trae el separador: `PEREZ<GOMEZ<<JUAN<CARLOS`.
    private func nombresDeMRZ(_ documento: NFCPassportModel) -> (apellidos: String, nombres: String) {
        guard let dg1 = documento.getDataGroup(.DG1) as? DataGroup1,
              let campo = dg1.elements["5B"] else {
            return (documento.lastName, documento.firstName)
        }

        let partes = campo.components(separatedBy: "<<")
        func limpiar(_ texto: String) -> String {
            texto.replacingOccurrences(of: "<", with: " ")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let apellidos = limpiar(partes.first ?? "")
        let nombres = limpiar(partes.dropFirst().joined(separator: " "))
        return (apellidos, nombres)
    }

    /// DG7 guarda la firma manuscrita escaneada.
    private func imagenDeFirma(_ documento: NFCPassportModel) -> UIImage? {
        guard let dg7 = documento.getDataGroup(.DG7) as? DataGroup7,
              !dg7.imageData.isEmpty else { return nil }
        return UIImage(data: Data(dg7.imageData))
    }

    /// DG13 no tiene parser en la librería: lo enseñamos en crudo, y de paso
    /// rescatamos las cadenas de texto legibles, que es donde suelen ir los datos
    /// específicos del país.
    private func leerDG13(_ documento: NFCPassportModel) -> (texto: String?, hex: String?) {
        guard let dg13 = documento.getDataGroup(.DG13), !dg13.data.isEmpty else {
            return (nil, nil)
        }
        let hex = dg13.data.map { String(format: "%02X", $0) }.joined()

        // Trozos imprimibles de 3 o más caracteres, como haría `strings`.
        var cadenas: [String] = []
        var actual = ""
        for byte in dg13.data {
            if (0x20...0x7E).contains(byte) {
                actual.append(Character(UnicodeScalar(byte)))
            } else {
                if actual.count >= 3 { cadenas.append(actual) }
                actual = ""
            }
        }
        if actual.count >= 3 { cadenas.append(actual) }

        return (cadenas.isEmpty ? nil : cadenas.joined(separator: " · "), hex)
    }

    /// El DG1 guarda la MRZ entera. En TD1 el elemento `53` concatena las dos zonas de
    /// datos opcionales: los 15 caracteres de la línea 1 (donde va el resto del serial
    /// cuando no cabe en 9) y los 11 de la línea 2 (la cédula nacional).
    private func leerZonaOpcional(_ documento: NFCPassportModel) -> (serial: String?, cedula: String?, mrz: String?) {
        guard let dg1 = documento.getDataGroup(.DG1) as? DataGroup1 else {
            return (nil, nil, nil)
        }
        let opcional = dg1.elements["53"] ?? ""
        let opcionalLinea1 = String(opcional.prefix(15))

        let serial = AnalizadorMRZ.reconstruirDocumento(
            campo: dg1.elements["5A"] ?? "",
            digito: dg1.elements["5F04"] ?? "",
            opcional: opcionalLinea1
        )
        // Se busca en las dos zonas juntas: la cédula está en la de la línea 1.
        return (serial.isEmpty ? nil : serial,
                AnalizadorMRZ.extraerCedulaNacional(opcional),
                dg1.elements["5F1F"])
    }

    /// Mensajes del diálogo de sistema del NFC, en español.
    private nonisolated func mensajeEnPantalla(_ mensaje: NFCViewDisplayMessage) -> String? {
        switch mensaje {
        case .requestPresentPassport:
            return "Acerca la cédula a la parte superior del reverso del iPhone y no la muevas."
        case .authenticatingWithPassport(let progreso):
            return "Autenticando con el chip…\n\(barra(progreso))"
        case .readingDataGroupProgress(let grupo, let progreso):
            return "Leyendo \(grupo)…\n\(barra(progreso))"
        case .successfulRead:
            return "Cédula leída correctamente."
        case .error:
            return nil // dejamos el texto por defecto de la librería
        default:
            return nil
        }
    }

    private nonisolated func barra(_ progreso: Int) -> String {
        let total = 20
        let llenos = max(0, min(total, progreso * total / 100))
        return String(repeating: "🟦", count: llenos) + String(repeating: "⬜️", count: total - llenos)
    }

    // MARK: - Errores

    /// Traduce los fallos más habituales a algo accionable. El caso importante es el
    /// `0x63 0x00` del Mutual Authenticate: significa llave MRZ incorrecta.
    private func explicar(_ error: Error) -> String {
        let texto = "\(error)"

        if texto.contains("6300") || texto.contains("0x63") || texto.lowercased().contains("invalidmrzkey") {
            return "La llave MRZ no es correcta (SW 0x63 0x00 en el Mutual Authenticate). "
                 + "Prueba con la otra opción de llave y revisa que las fechas estén en YYMMDD."
        }
        if texto.lowercased().contains("responseerror") {
            return "El chip rechazó un comando: \(texto)"
        }
        if texto.lowercased().contains("userCanceled".lowercased()) || texto.contains("200") {
            return "Lectura cancelada."
        }
        if texto.lowercased().contains("connection") || texto.lowercased().contains("tagnotvalid") {
            return "Se perdió el contacto con el chip. Apoya la cédula sin moverla en la parte superior del reverso."
        }
        return "Fallo de lectura: \(texto)"
    }

    private func anotar(_ linea: String) {
        bitacora.append(linea)
    }
}
