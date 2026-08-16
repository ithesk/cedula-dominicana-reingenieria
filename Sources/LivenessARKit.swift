import SwiftUI
import UIKit
import ARKit
import SceneKit

/// Resultado del control de vida (anti-spoofing) local.
struct ResultadoLiveness {
    var soportado: Bool          // el dispositivo tiene TrueDepth / face tracking
    var vivo: Bool               // profundidad 3D + retos superados
    var profundidad3D: Bool      // se rastreó geometría facial 3D (una foto plana no la tiene)
    var retosSuperados: [String]
    var imagen: UIImage?         // fotograma capturado para el emparejamiento
    var motivo: String

    static func noSoportado() -> ResultadoLiveness {
        ResultadoLiveness(soportado: false, vivo: false, profundidad3D: false,
                          retosSuperados: [], imagen: nil,
                          motivo: "Este dispositivo no tiene cámara TrueDepth; sin control de vida.")
    }
}

/// Control de vida con ARKit. Rastrea la cara en 3D (TrueDepth) y pide retos activos —
/// parpadeo y abrir la boca. Una foto o una pantalla son planas: no producen geometría 3D
/// estable y no parpadean a demanda, así que fallan.
///
/// ⚠️ Es un liveness **real pero no certificado** (no iBeta / ISO 30107-3). Derrota foto y
/// pantalla; una máscara 3D de alta calidad o un deepfake por inyección quedan fuera — como
/// en casi todos los SDK. Para identidad regulada hace falta un SDK certificado.
struct LivenessARKit: UIViewControllerRepresentable {
    var alTerminar: (ResultadoLiveness) -> Void

    static var soportado: Bool { ARFaceTrackingConfiguration.isSupported }

    func makeUIViewController(context: Context) -> LivenessController {
        let c = LivenessController()
        c.alTerminar = alTerminar
        return c
    }
    func updateUIViewController(_ uiViewController: LivenessController, context: Context) {}
}

final class LivenessController: UIViewController, ARSessionDelegate {

    var alTerminar: ((ResultadoLiveness) -> Void)?

    private let sceneView = ARSCNView()
    private let etiqueta = UILabel()
    private let progreso = UILabel()

    // Retos por superar, en orden. Blendshapes muy fiables y que una foto no puede fingir.
    private enum Reto: String, CaseIterable {
        case parpadeo = "Parpadea"
        case boca = "Abre la boca"
    }
    private var pendientes: [Reto] = []
    private var superados: [String] = []
    private var profundidadVista = false
    private var terminado = false
    private var framesConCara = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        view.addSubview(sceneView)

        montarUI()
        // Orden de retos aleatorio para que no sea predecible.
        pendientes = Reto.allCases.shuffled()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        etiqueta.frame = CGRect(x: 20, y: view.bounds.height - 160, width: view.bounds.width - 40, height: 60)
        progreso.frame = CGRect(x: 20, y: view.bounds.height - 96, width: view.bounds.width - 40, height: 30)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARFaceTrackingConfiguration.isSupported else {
            finalizar(ResultadoLiveness.noSoportado()); return
        }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        actualizarInstruccion()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    private func montarUI() {
        for l in [etiqueta, progreso] {
            l.textColor = .white
            l.textAlignment = .center
            l.numberOfLines = 0
            view.addSubview(l)
        }
        etiqueta.font = .systemFont(ofSize: 22, weight: .bold)
        progreso.font = .systemFont(ofSize: 14, weight: .medium)
        progreso.textColor = .init(white: 1, alpha: 0.7)

        let cancelar = UIButton(type: .system)
        cancelar.setTitle("Cancelar", for: .normal)
        cancelar.tintColor = .white
        cancelar.frame = CGRect(x: 16, y: 56, width: 90, height: 40)
        cancelar.addTarget(self, action: #selector(cancelar(_:)), for: .touchUpInside)
        view.addSubview(cancelar)
    }

    @objc private func cancelar(_ sender: Any) {
        finalizar(ResultadoLiveness(soportado: true, vivo: false, profundidad3D: profundidadVista,
                                    retosSuperados: superados, imagen: nil, motivo: "Cancelado."))
    }

    private func actualizarInstruccion() {
        guard let reto = pendientes.first else {
            etiqueta.text = "Perfecto"; progreso.text = ""; return
        }
        etiqueta.text = reto.rawValue
        progreso.text = "Reto \(superados.count + 1) de \(superados.count + pendientes.count)  ·  mira a la cámara frontal"
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !terminado,
              let cara = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              cara.isTracked else { return }

        // Geometría 3D rastreada de forma estable = señal de profundidad (foto plana no lo logra).
        framesConCara += 1
        if framesConCara > 15 { profundidadVista = true }

        guard let reto = pendientes.first else { capturarYFinalizar(frame); return }

        let bs = cara.blendShapes
        func v(_ k: ARFaceAnchor.BlendShapeLocation) -> Float { bs[k]?.floatValue ?? 0 }

        let superado: Bool
        switch reto {
        case .parpadeo: superado = v(.eyeBlinkLeft) > 0.55 && v(.eyeBlinkRight) > 0.55
        case .boca:     superado = v(.jawOpen) > 0.45
        }

        if superado {
            superados.append(reto.rawValue)
            pendientes.removeFirst()
            DispatchQueue.main.async { [weak self] in self?.actualizarInstruccion() }
            if pendientes.isEmpty { capturarYFinalizar(frame) }
        }
    }

    private func capturarYFinalizar(_ frame: ARFrame) {
        guard !terminado else { return }
        terminado = true
        let imagen = imagenDe(frame)
        let vivo = profundidadVista && !superados.isEmpty
        let motivo = vivo
            ? "Cara 3D rastreada y \(superados.count) reto(s) superado(s). Liveness local (no certificado)."
            : "No se confirmó la vida (profundidad o retos insuficientes)."
        finalizar(ResultadoLiveness(soportado: true, vivo: vivo, profundidad3D: profundidadVista,
                                    retosSuperados: superados, imagen: imagen, motivo: motivo))
    }

    private func imagenDe(_ frame: ARFrame) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: frame.capturedImage)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        // La cámara frontal entrega el fotograma en horizontal y espejado.
        return UIImage(cgImage: cg, scale: 1, orientation: .leftMirrored)
    }

    private func finalizar(_ r: ResultadoLiveness) {
        DispatchQueue.main.async { [weak self] in self?.alTerminar?(r) }
    }
}
