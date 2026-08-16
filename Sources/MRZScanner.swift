import SwiftUI
import AVFoundation
import Vision

// MARK: - Cámara

/// Hoja con la cámara para leer la MRZ del reverso de la cédula.
struct MRZScannerView: UIViewControllerRepresentable {
    var alLeer: (DatosMRZ) -> Void
    var alCerrar: () -> Void

    func makeUIViewController(context: Context) -> MRZCaptureController {
        let controlador = MRZCaptureController()
        controlador.alLeer = alLeer
        controlador.alCerrar = alCerrar
        return controlador
    }

    func updateUIViewController(_ uiViewController: MRZCaptureController, context: Context) {}
}

final class MRZCaptureController: UIViewController {

    var alLeer: ((DatosMRZ) -> Void)?
    var alCerrar: (() -> Void)?

    private let sesion = AVCaptureSession()
    private let cola = DispatchQueue(label: "mrz.captura")
    private var capaPrevia: AVCaptureVideoPreviewLayer?
    private var procesando = false
    private var yaEntregado = false

    /// Exigimos dos lecturas idénticas seguidas antes de dar la MRZ por buena: el OCR
    /// acierta casi siempre, pero un solo fotograma malo arruina la llave entera.
    private var candidataAnterior: String?

    private let guia = UIView()
    private let etiqueta = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        montarInterfaz()
        pedirPermisoYArrancar()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        capaPrevia?.frame = view.bounds
        let alto = view.bounds.height * 0.22
        guia.frame = CGRect(x: 16,
                            y: view.bounds.midY - alto / 2,
                            width: view.bounds.width - 32,
                            height: alto)
        etiqueta.frame = CGRect(x: 16,
                                y: guia.frame.maxY + 16,
                                width: view.bounds.width - 32,
                                height: 60)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cola.async { [sesion] in
            if sesion.isRunning { sesion.stopRunning() }
        }
    }

    private func montarInterfaz() {
        guia.layer.borderColor = UIColor.systemYellow.cgColor
        guia.layer.borderWidth = 2
        guia.layer.cornerRadius = 8
        guia.backgroundColor = .clear
        view.addSubview(guia)

        etiqueta.text = "Encuadra las 3 líneas del reverso dentro del recuadro."
        etiqueta.textColor = .white
        etiqueta.numberOfLines = 0
        etiqueta.textAlignment = .center
        etiqueta.font = .systemFont(ofSize: 15, weight: .medium)
        view.addSubview(etiqueta)

        let cerrar = UIButton(type: .system)
        cerrar.setTitle("Cancelar", for: .normal)
        cerrar.tintColor = .white
        cerrar.addTarget(self, action: #selector(cerrar(_:)), for: .touchUpInside)
        cerrar.frame = CGRect(x: 16, y: 56, width: 100, height: 44)
        view.addSubview(cerrar)
    }

    @objc private func cerrar(_ sender: Any) {
        alCerrar?()
    }

    private func pedirPermisoYArrancar() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configurarSesion()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] concedido in
                guard concedido else {
                    DispatchQueue.main.async { self?.mostrarSinPermiso() }
                    return
                }
                DispatchQueue.main.async { self?.configurarSesion() }
            }
        default:
            mostrarSinPermiso()
        }
    }

    private func mostrarSinPermiso() {
        etiqueta.text = "Sin permiso de cámara. Actívalo en Ajustes › Validador Cédula, o escribe la MRZ a mano."
    }

    private func configurarSesion() {
        sesion.beginConfiguration()
        sesion.sessionPreset = .hd1920x1080

        guard let camara = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let entrada = try? AVCaptureDeviceInput(device: camara),
              sesion.canAddInput(entrada) else {
            sesion.commitConfiguration()
            etiqueta.text = "No se pudo abrir la cámara."
            return
        }
        sesion.addInput(entrada)

        // Enfoque cercano: la MRZ se lee a pocos centímetros.
        try? camara.lockForConfiguration()
        if camara.isFocusModeSupported(.continuousAutoFocus) {
            camara.focusMode = .continuousAutoFocus
        }
        camara.unlockForConfiguration()

        let salida = AVCaptureVideoDataOutput()
        salida.alwaysDiscardsLateVideoFrames = true
        salida.setSampleBufferDelegate(self, queue: cola)
        guard sesion.canAddOutput(salida) else {
            sesion.commitConfiguration()
            return
        }
        sesion.addOutput(salida)
        sesion.commitConfiguration()

        let capa = AVCaptureVideoPreviewLayer(session: sesion)
        capa.videoGravity = .resizeAspectFill
        capa.frame = view.bounds
        view.layer.insertSublayer(capa, at: 0)
        capaPrevia = capa

        cola.async { [sesion] in
            if !sesion.isRunning { sesion.startRunning() }
        }
    }
}

extension MRZCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !procesando, !yaEntregado,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        procesando = true

        let peticion = VNRecognizeTextRequest { [weak self] peticion, _ in
            defer { self?.procesando = false }
            guard let observaciones = peticion.results as? [VNRecognizedTextObservation] else { return }
            let lineas = observaciones.compactMap { $0.topCandidates(1).first?.string }
            self?.evaluar(lineas)
        }
        peticion.recognitionLevel = .accurate
        peticion.usesLanguageCorrection = false   // la MRZ no es lenguaje natural
        peticion.minimumTextHeight = 0.02

        let manejador = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
        do {
            try manejador.perform([peticion])
        } catch {
            procesando = false
        }
    }

    private func evaluar(_ lineas: [String]) {
        // Nos quedamos con las que parecen MRZ, en el orden en que aparecen.
        let candidatas = lineas.filter { AnalizadorMRZ.pareceLineaMRZ($0) }
        guard candidatas.count >= 3 else { return }

        let tres = Array(candidatas.suffix(3))
        guard let datos = AnalizadorMRZ.analizar(lineas: tres) else { return }

        let huella = datos.numeroDocumento + datos.fechaNacimiento + datos.fechaExpiracion
        guard huella == candidataAnterior else {
            candidataAnterior = huella
            return
        }

        yaEntregado = true
        DispatchQueue.main.async { [weak self] in
            let generador = UINotificationFeedbackGenerator()
            generador.notificationOccurred(.success)
            self?.alLeer?(datos)
        }
    }
}
