import SwiftUI
import UniformTypeIdentifiers

/// Fila etiqueta/valor. Hecha a mano porque `LabeledContent` es iOS 16 y el proyecto
/// apunta a iOS 15.
private struct Fila<Contenido: View>: View {
    let titulo: String
    @ViewBuilder let contenido: Contenido

    init(_ titulo: String, @ViewBuilder contenido: () -> Contenido) {
        self.titulo = titulo
        self.contenido = contenido()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(titulo)
            Spacer(minLength: 12)
            contenido
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private extension Fila where Contenido == Text {
    init(_ titulo: String, valor: String) {
        self.init(titulo) { Text(valor.isEmpty ? "—" : valor) }
    }
}

struct ContentView: View {

    // Los tres campos de la MRZ son, juntos, la llave de acceso al chip: no se dejan
    // escritos en el código. Empiezan vacíos y se recuerdan solo en este dispositivo,
    // así que se teclean o se escanean una vez y ya quedan para las siguientes pruebas.
    @AppStorage("mrz.documento") private var documento = ""
    @AppStorage("mrz.nacimiento") private var nacimiento = ""
    @AppStorage("mrz.expiracion") private var expiracion = ""
    @State private var opcion: OpcionLlave = .completa

    @State private var mostrarEscaner = false
    @State private var mostrarImportadorCSCA = false
    @State private var cedulaNacionalMRZ: String?
    @State private var avisoMRZ: String?

    @StateObject private var lector = CedulaReader()
    @StateObject private var explorador = ExploradorChip()

    // Fase 3 · titular
    @State private var mostrarSelfie = false
    @State private var mostrarLiveness = false
    @State private var resultadoFacial: ResultadoFacial?
    @State private var resultadoLiveness: ResultadoLiveness?
    @State private var comparandoCara = false
    private let comparador: ComparadorFacial = ComparadorCoreML()

    // Fase 4 · decisión
    @State private var consentimiento = false
    @State private var constanciaTexto: String?
    @State private var constanciaGuardada: URL?

    var body: some View {
        Group {
#if DEBUG
            if let n = demoSeccion {
                demoBody(n)
            } else {
                appReal
            }
#else
            appReal
#endif
        }
    }

    private var appReal: some View {
        NavigationView {
            Form {
                seccionMRZ
                seccionLlave
                seccionAccion
                if let datos = lector.datos {
                    seccionDecision(datos)
                    seccionSeguridad(datos.seguridad)
                    if let foto = datos.foto {
                        seccionTitular(foto)
                    }
                    seccionResultado(datos)
                }
                seccionBitacora
                seccionExploracion
            }
            .navigationTitle("Validador de cédula")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $mostrarEscaner) {
                MRZScannerView(
                    alLeer: { datos in
                        aplicar(datos)
                        mostrarEscaner = false
                    },
                    alCerrar: { mostrarEscaner = false }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $mostrarSelfie) {
                SelfiePicker(
                    alCapturar: { imagen in
                        mostrarSelfie = false
                        resultadoLiveness = nil          // captura simple: sin liveness
                        verificarTitular(selfie: imagen)
                    },
                    alCancelar: { mostrarSelfie = false }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $mostrarLiveness) {
                LivenessARKit { resultado in
                    mostrarLiveness = false
                    resultadoLiveness = resultado
                    if let imagen = resultado.imagen, resultado.vivo {
                        verificarTitular(selfie: imagen)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .navigationViewStyle(.stack)
    }

#if DEBUG
    /// Sección a mostrar en modo demo (para capturas), leída de la variable de entorno.
    private var demoSeccion: Int? {
        guard let s = ProcessInfo.processInfo.environment["DEMO_SECCION"], let n = Int(s) else { return nil }
        return n
    }

    /// Renderiza UNA sola sección con datos ficticios, a pantalla completa.
    private func demoBody(_ n: Int) -> some View {
        NavigationView {
            Form {
                if let datos = lector.datos {
                    switch n {
                    case 0: seccionDecision(datos)
                    case 1: seccionSeguridad(datos.seguridad)
                    case 2: if let f = datos.foto { seccionTitular(f) }
                    default: seccionResultado(datos)
                    }
                }
            }
            .navigationTitle(["Decisión", "Seguridad", "Titular", "Datos del chip"][min(max(n, 0), 3)])
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .onAppear {
            lector.cargarDemo()
            resultadoFacial = ResultadoFacial(caraEnSelfie: true, caraEnReferencia: true,
                puntuacion: 0.82, umbral: 0.62, livenessComprobado: true,
                aptoProduccion: true, motivo: "Emparejamiento de demostración (datos ficticios).")
            resultadoLiveness = ResultadoLiveness(soportado: true, vivo: true, profundidad3D: true,
                retosSuperados: ["Parpadea", "Abre la boca"], imagen: nil, motivo: "Demo.")
            consentimiento = true
        }
    }
#endif

    private func verificarTitular(selfie: UIImage) {
        guard let referencia = lector.datos?.foto else { return }
        comparandoCara = true
        resultadoFacial = nil
        let liveness = resultadoLiveness?.vivo ?? false
        Task.detached {
            var r = comparador.comparar(selfie: selfie, referencia: referencia)
            r.livenessComprobado = liveness      // la vida la aporta ARKit
            await MainActor.run {
                resultadoFacial = r
                comparandoCara = false
            }
        }
    }

    private func seccionDecision(_ datos: DatosCedula) -> some View {
        let decision = MotorDecision.evaluar(
            auth: lector.autenticidad,
            facial: resultadoFacial,
            fechaExpiracionYYMMDD: datos.fechaExpiracion)
        return Section {
            // Semáforo global.
            HStack(spacing: 14) {
                Image(systemName: decision.global.simbolo)
                    .font(.system(size: 34))
                    .foregroundColor(decision.global.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(decision.titulo).font(.title3).bold()
                        .foregroundColor(decision.global.color)
                    Text(decision.resumen).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)

            // Los tres controles.
            ForEach(Array(decision.checks.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 10) {
                    Image(systemName: c.estado.simbolo).foregroundColor(c.estado.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.etiqueta).font(.subheadline)
                        Text(c.detalle).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }

            // Consentimiento + constancia (Ley 172-13).
            Toggle(isOn: $consentimiento) {
                Text("El titular consiente la verificación").font(.footnote)
            }
            Button {
                let texto = Constancia.generar(
                    decision,
                    referencia: Constancia.enmascarar(datos.cedulaNacional),
                    consentimiento: consentimiento)
                constanciaTexto = texto
                constanciaGuardada = Constancia.guardar(texto)
            } label: {
                Label("Generar constancia", systemImage: "doc.badge.plus")
            }
            .disabled(!consentimiento)

            if let texto = constanciaTexto {
                Text(texto)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                if let url = constanciaGuardada {
                    Text("Guardada: \(url.lastPathComponent)")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Decisión (Fase 4)")
        } footer: {
            Text("Semáforo único de los tres controles. La constancia no guarda foto ni biometría — solo la decisión, una referencia enmascarada y el consentimiento (Ley 172-13). La vigencia es offline (fecha de la MRZ); el estado en el registro necesitaría la API de OGTIC.")
        }
    }

    private func seccionTitular(_ referencia: UIImage) -> some View {
        Section {
            if let r = resultadoFacial {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: r.veredicto.simbolo)
                        .font(.title2).foregroundColor(r.veredicto.nivel.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.veredicto.titulo).font(.headline)
                            .foregroundColor(r.veredicto.nivel.color)
                        if let p = r.puntuacion {
                            Text("Similitud: \(Int(p * 100)) %  (umbral \(Int(r.umbral * 100)) %)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Text(r.motivo).font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let liv = resultadoLiveness {
                HStack(spacing: 10) {
                    Image(systemName: liv.vivo ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundColor(liv.vivo ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(liv.vivo ? "Persona viva (liveness local)" : "Vida no confirmada")
                            .font(.subheadline)
                        Text((liv.profundidad3D ? "Profundidad 3D ✓ · " : "")
                             + (liv.retosSuperados.isEmpty ? "" : "Retos: \(liv.retosSuperados.joined(separator: ", "))"))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }

            Button {
                if LivenessARKit.soportado { mostrarLiveness = true } else { mostrarSelfie = true }
            } label: {
                HStack {
                    if comparandoCara { ProgressView().padding(.trailing, 4) }
                    Label(resultadoFacial == nil ? "Verificar titular"
                                                 : "Repetir verificación",
                          systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            .disabled(comparandoCara)
        } header: {
            Text("Titular (Fase 3)")
        } footer: {
            Text(pieTitular)
        }
    }

    private var pieTitular: String {
        let live = LivenessARKit.soportado
            ? "Liveness: ARKit + TrueDepth (profundidad 3D + retos). Real, no certificado — derrota foto y pantalla; para identidad regulada hace falta un SDK certificado (iBeta/ISO 30107-3)."
            : "Este dispositivo no tiene TrueDepth: captura simple sin liveness."
        let match = comparador.aptoProduccion
            ? "Emparejamiento: \(comparador.nombre)."
            : "Emparejamiento: \(comparador.nombre). Añade un modelo Core ML (FaceEmbedding.mlmodel) para matching de producción."
        return match + " " + live
    }

    // MARK: - Secciones

    private var seccionMRZ: some View {
        Section {
            Fila("Documento") {
                TextField("serial de la cédula", text: $documento)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
            }
            Fila("Nacimiento") {
                TextField("YYMMDD", text: $nacimiento)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
            }
            Fila("Expiración") {
                TextField("YYMMDD", text: $expiracion)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
            }

            Button {
                mostrarEscaner = true
            } label: {
                Label("Escanear MRZ con la cámara", systemImage: "text.viewfinder")
            }

            if let cedula = cedulaNacionalMRZ {
                Fila("Cédula en la MRZ", valor: cedula)
                    .font(.footnote)
            }
            if let aviso = avisoMRZ {
                Text(aviso)
                    .font(.footnote)
                    .foregroundColor(.orange)
            }

            if !documento.isEmpty || !nacimiento.isEmpty || !expiracion.isEmpty {
                Button("Olvidar estos datos", role: .destructive) {
                    documento = ""
                    nacimiento = ""
                    expiracion = ""
                    cedulaNacionalMRZ = nil
                    avisoMRZ = nil
                }
            }
        } header: {
            Text("Datos de la MRZ (reverso)")
        } footer: {
            Text("Las fechas van en YYMMDD, no en DD/MM/AAAA. El escáner las rellena solo.\n\nEstos tres campos son la llave del chip y quedan guardados en el dispositivo, sin cifrar, hasta que pulses «Olvidar estos datos».")
        }
    }

    private var seccionLlave: some View {
        Section {
            Picker("Forma de la llave", selection: $opcion) {
                ForEach(OpcionLlave.allCases) { caso in
                    Text(caso.titulo).tag(caso)
                }
            }
            .pickerStyle(.segmented)

            Fila("Campo de documento") {
                Text(opcion.campoDeEjemplo(documento))
                    .font(.system(.footnote, design: .monospaced))
            }
        } header: {
            Text("Llave BAC")
        } footer: {
            Text("El serial dominicano tiene 10 caracteres y la MRZ admite 9. Si sale «SW 0x63 0x00», cambia a la otra opción y vuelve a intentarlo.")
        }
    }

    private var seccionAccion: some View {
        Section {
            Button {
                Task {
                    await lector.leer(documento: documento,
                                      nacimiento: nacimiento,
                                      expiracion: expiracion,
                                      opcion: opcion)
                }
            } label: {
                HStack {
                    if lector.leyendo {
                        ProgressView().padding(.trailing, 4)
                    }
                    Text(lector.leyendo ? "Leyendo…" : "Leer cédula")
                }
            }
            .disabled(lector.leyendo)

            if case .fallo(let motivo) = lector.estado {
                Text(motivo)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        }
    }

    private func seccionResultado(_ datos: DatosCedula) -> some View {
        Section(header: Text("Datos del chip")) {
            HStack(alignment: .top, spacing: 16) {
                if let foto = datos.foto {
                    Image(uiImage: foto)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemFill))
                        .frame(width: 96, height: 120)
                        .overlay(Text("sin DG2").font(.caption2).foregroundColor(.secondary))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(datos.nombreCompleto)
                        .font(.headline)
                    Text(datos.cedulaNacional ?? datos.serialCompleto)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("\(datos.nacionalidad) · \(datos.sexo)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)

            Fila("Apellidos", valor: datos.apellidos)
            Fila("Nombres", valor: datos.nombres)
            if let cedula = datos.cedulaNacional {
                Fila("Cédula", valor: cedula)
            }
            Fila("Serial", valor: datos.serialCompleto)
            Fila("Nacionalidad", valor: datos.nacionalidad)
            Fila("País emisor", valor: datos.paisEmisor)
            Fila("Sexo", valor: datos.sexo)
            Fila("Nacimiento", valor: datos.fechaNacimiento)
            Fila("Expiración", valor: datos.fechaExpiracion)
            if let lugar = datos.lugarNacimiento { Fila("Lugar de nacimiento", valor: lugar) }
            if let profesion = datos.profesion { Fila("Profesión", valor: profesion) }
            if let direccion = datos.direccion { Fila("Dirección", valor: direccion) }
            if let telefono = datos.telefono { Fila("Teléfono", valor: telefono) }
            if let numero = datos.numeroPersonal, !numero.isEmpty { Fila("Nº personal", valor: numero) }

            if let emision = datos.fechaEmision { Fila("Emisión", valor: emision) }
            if let autoridad = datos.autoridadEmisora { Fila("Autoridad", valor: autoridad) }
            if let observaciones = datos.observaciones { Fila("Observaciones", valor: observaciones) }
            if let personalizacion = datos.momentoPersonalizacion {
                Fila("Personalizado", valor: personalizacion)
            }

            if let firma = datos.firma {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Firma (DG7)").font(.caption).foregroundColor(.secondary)
                    Image(uiImage: firma)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 80)
                }
                .padding(.vertical, 4)
            }

            Fila("Grupos leídos", valor: datos.gruposLeidos.joined(separator: ", "))

            if let mrz = datos.mrzCruda {
                DisclosureGroup("MRZ del chip") {
                    Text(mrz)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if datos.dg13Texto != nil || datos.dg13Hex != nil {
                DisclosureGroup("DG13 · datos nacionales (sin parser)") {
                    if let texto = datos.dg13Texto {
                        Text(texto)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let hex = datos.dg13Hex {
                        Text(hex)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bannerVeredicto(_ a: ResultadoAuth) -> some View {
        let v = a.veredicto
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: v.simbolo)
                .font(.title2)
                .foregroundColor(v.nivel.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(v.titulo).font(.headline).foregroundColor(v.nivel.color)
                Text(v.detalle).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var filaCSCA: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: lector.hayCSCA ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundColor(lector.hayCSCA ? .green : .secondary)
                Text(lector.hayCSCA ? "Certificado raíz (CSCA) cargado" : "Sin certificado raíz (CSCA)")
                    .font(.subheadline)
                Spacer()
            }
            Text(lector.hayCSCA
                 ? "El validador puede probar que el emisor es la JCE."
                 : "Sin él se lee y se comprueba la integridad, pero no se puede probar el emisor. Impórtalo cuando la JCE lo publique o te lo entregue (.pem).")
                .font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 14) {
                Button {
                    mostrarImportadorCSCA = true
                } label: {
                    Label(lector.hayCSCA ? "Reemplazar CSCA…" : "Importar CSCA (.pem)…",
                          systemImage: "square.and.arrow.down")
                }
                .font(.footnote)
                if lector.hayCSCA {
                    Button(role: .destructive) {
                        AutenticidadPasiva.borrarCSCA()
                        lector.reverificarAutenticidad()
                    } label: { Text("Quitar").font(.footnote) }
                }
            }
        }
        .fileImporter(isPresented: $mostrarImportadorCSCA,
                      allowedContentTypes: [.text, .data],
                      allowsMultipleSelection: false) { resultado in
            if case .success(let urls) = resultado, let url = urls.first {
                if AutenticidadPasiva.importarCSCA(desde: url) {
                    lector.reverificarAutenticidad()
                }
            }
        }
    }

    private func seccionSeguridad(_ s: Seguridad) -> some View {
        Section {
            if let a = lector.autenticidad {
                bannerVeredicto(a)
            }
            sello("Canal cifrado (PACE)", s.pace.lowercased().contains("success"),
                  "La llave derivada de la MRZ abrió el chip.")
            sello("Chip no clonado (Chip Auth.)", s.chipAutenticado,
                  "El chip probó tener la clave privada del DG14. Copiar los datos a un chip virgen no supera esto.")
            sello("Datos sin manipular (hashes SOD)", s.sinManipular,
                  "Los hashes de los grupos leídos cuadran con los que declara el SOD.")
            sello("Firma del emisor (Passive Auth.)", s.firmaVerificada,
                  s.firmaVerificada ? "Verificada." : "PENDIENTE: necesita el CSCA de la JCE. Sin esto, un falsificador con su propio SOD autofirmado pasaría los sellos de arriba.")

            if !s.gruposDeclarados.isEmpty {
                Fila("El SOD declara", valor: s.gruposDeclarados.joined(separator: ", "))
                    .font(.caption)
            }

            filaCSCA
        } header: {
            Text("Seguridad")
        } footer: {
            Text("Los tres primeros sellos no necesitan la JCE. El cuarto —la firma del emisor— se cierra al importar el certificado raíz (CSCA) abajo.")
        }
    }

    private func sello(_ titulo: String, _ ok: Bool, _ explicacion: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal")
                    .foregroundColor(ok ? .green : .orange)
                Text(titulo)
                Spacer()
            }
            Text(explicacion)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var seccionBitacora: some View {
        Section(header: Text("Bitácora")) {
            if lector.bitacora.isEmpty {
                Text("Sin actividad todavía.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(lector.bitacora.enumerated()), id: \.offset) { _, linea in
                    Text(linea)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                if !lector.traza.isEmpty {
                    DisclosureGroup("Traza cruda (\(lector.traza.count) líneas)") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(lector.traza.enumerated()), id: \.offset) { _, linea in
                                    Text(linea)
                                        .font(.system(size: 9, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(height: 280)
                    }
                }

                Button("Limpiar", role: .destructive) { lector.limpiar() }
            }
        }
    }

    private var seccionExploracion: some View {
        Section {
            Button {
                explorador.explorar()
            } label: {
                HStack {
                    if explorador.explorando { ProgressView().padding(.trailing, 4) }
                    Label(explorador.explorando ? "Explorando…" : "Explorar el chip",
                          systemImage: "magnifyingglass")
                }
            }
            .disabled(explorador.explorando)

            if !explorador.aidEncontrados.isEmpty {
                ForEach(explorador.aidEncontrados, id: \.self) { aid in
                    Fila("AID", valor: aid)
                        .font(.system(.footnote, design: .monospaced))
                }
                Text("Para poder seleccionarlos hay que añadirlos a `iso7816.select-identifiers` en el Info.plist y volver a compilar.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button {
                explorador.reconocerPIN()
            } label: {
                Label("Reconocer PIN (sin consumir intentos)", systemImage: "lock.shield")
            }
            .disabled(explorador.explorando)

            Button {
                explorador.interrogarSSCD()
            } label: {
                Label("Interrogar SSCD (solo lectura)", systemImage: "signature")
            }
            .disabled(explorador.explorando)

            if let ref = explorador.refPIN {
                Fila("Referencia del PIN", valor: String(format: "%02X", ref))
            }
            if let intentos = explorador.intentosRestantes {
                Fila("Intentos restantes", valor: "\(intentos)")
                    .foregroundColor(intentos <= 1 ? .red : .primary)
            }

            if !explorador.bitacora.isEmpty {
                DisclosureGroup("Salida (\(explorador.bitacora.count) líneas)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(explorador.bitacora.enumerated()), id: \.offset) { _, linea in
                                Text(linea)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 300)
                }
                Button("Limpiar exploración", role: .destructive) { explorador.limpiar() }
            }
        } header: {
            Text("Exploración del chip")
        } footer: {
            Text("Solo SELECT y READ BINARY: no toca contadores de PIN ni escribe nada. Lee el EF.DIR para descubrir qué applets tiene la tarjeta además del eMRTD.")
        }
    }

    // MARK: - Escáner

    private func aplicar(_ datos: DatosMRZ) {
        documento = datos.numeroDocumento
        nacimiento = datos.fechaNacimiento
        expiracion = datos.fechaExpiracion
        cedulaNacionalMRZ = datos.cedulaNacional
        avisoMRZ = datos.digitosCuadran
            ? nil
            : "Los dígitos de control de las fechas no cuadran: revisa los campos antes de leer."
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
