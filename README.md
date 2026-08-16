# Cédula dominicana con chip — reingeniería y validador

**Autor: Pablo Holguín** · investigación independiente, 2026

Reingeniería del chip de la nueva cédula dominicana (emisión 2026) y un **validador de
identidad de cuatro fases, 100 % offline**, para iOS. Todo lo afirmado aquí se verificó
leyendo el plástico o analizando sus volcados —no de documentación, que no existe
públicamente—; donde una conclusión se apoya en pocas muestras o en el flujo de trabajo, y
no en la propia traza, está dicho.

> **No es una publicación de la Junta Central Electoral.** Investigación con fines de estudio,
> realizada sobre cédulas propias. Este repositorio **no contiene datos personales**: todos
> los valores de ejemplo son ficticios o genéricos.

📄 **Dossier visual completo:** ver `dossier.html` (o la versión publicada del proyecto).

---

## Qué se descubrió (verificado sobre el chip)

- **Es un eMRTD ICAO 9303** — el mismo estándar que un pasaporte electrónico. Por eso una
  librería de pasaportes lo lee sin cambios.
- **Acceso por PACE, no BAC** — ECDH sobre curva **secp384r1**, AES-256, SHA-256.
- **La llave se deriva de la MRZ** del reverso; el serial de 10 caracteres obliga a elegir
  entre dos formas de armarla (opción A/B). La correcta: **A** (serial completo + dígito).
- **Nueve grupos de datos**, no dos: MRZ, foto, firma manuscrita, lugar de nacimiento, fecha
  de emisión, datos de registro civil, claves de Chip Authentication. Huellas (DG3) presentes
  pero bloqueadas por EAC.
- **Anti-clonado real** (Chip Authentication) e **integridad verificada por cuenta propia**
  (SHA-256 de cada grupo contra el SOD, 7/7).
- **Cinco applets** en el chip: `ICAO`, `DomRepEID` (raíz), `CitizenID` (autenticación),
  `SSCD` (firma cualificada, sellado), `ePKI` (PKCS#15, en *inicialización*).
- **La firma cualificada aún no está activa:** la JCE se acreditó como autoridad
  certificadora el 17-dic-2025, pero el servicio al ciudadano no está lanzado. El `ePKI` está
  apagado en todos los ejemplares.
- **La cadena de confianza** está verificada en dos de sus tres eslabones (datos→SOD y
  DSC→SOD). Falta el CSCA de la JCE — que no está en el chip ni en las master lists
  internacionales, y probablemente solo lo reparta la JCE.
- **El caso DG13:** los primeros dígitos de la cédula son un código de **oficialía** real; el
  campo `5F12` guarda la oficialía de **emisión**, no la del titular (corrección hecha con dos
  muestras).

Detalle completo, con el método y los fallos de análisis propios, en el `dossier.html`.

## El validador (cuatro fases, offline)

| Fase | Qué hace | Estado |
|---|---|---|
| 1 · Leer | MRZ → PACE → 9 grupos + foto | funcionando |
| 2 · Genuina | cadena de Passive Authentication; **CSCA como hueco** | construida |
| 3 · Titular | emparejamiento (Core ML) + liveness (ARKit·TrueDepth); **modelo como hueco** | construida |
| 4 · Decisión | semáforo de los tres controles + constancia mínima (Ley 172-13) | construida |

Los **dos huecos** (el certificado raíz de la JCE y un modelo Core ML de rostro) se enchufan
sin tocar el flujo, mediante `AutenticidadPasiva` y el protocolo `ComparadorFacial`.

## Estructura

```
ValidadorCedula/
├── project.yml                 XcodeGen (target, SPM, firma)
├── probar.sh                   pruebas de la lógica pura en el Mac (27/27)
├── dossier.html                dossier técnico visual
├── Pruebas/main.swift          comprobaciones con datos ficticios
├── herramientas/abrir-cert.py  utilidad de escritorio (PC/SC) — ver aviso abajo
└── Sources/
    ├── ValidadorApp.swift      @main
    ├── ContentView.swift       UI y flujo (4 fases)
    ├── LlaveMRZ.swift          derivación de la llave + dígitos ICAO
    ├── AnalizadorMRZ.swift     parser TD1 puro (testeable sin cámara)
    ├── MRZScanner.swift        cámara + Vision (OCR de la MRZ)
    ├── CedulaReader.swift      ÚNICO punto de contacto con NFCPassportReader
    ├── AutenticidadPasiva.swift  Fase 2: cadena de confianza + hueco del CSCA
    ├── FaceMatch.swift         Fase 3: protocolo del comparador + relleno Vision
    ├── ComparadorCoreML.swift  Fase 3: embeddings faciales (hueco del modelo)
    ├── LivenessARKit.swift     Fase 3: liveness TrueDepth (profundidad 3D + retos)
    ├── DecisionFinal.swift     Fase 4: semáforo + constancia
    ├── ExploradorChip.swift    sonda de APDUs crudos (mapa de applets)
    └── …
```

## Cómo ejecutarlo

```bash
brew install xcodegen
xcodegen generate
open ValidadorCedula.xcodeproj
```

Requiere **iPhone físico** (el simulador no tiene NFC), **cuenta Apple Developer de pago**
(el entitlement NFC no va con cuenta gratis) e **iOS 15+**.

La lógica pura (llave y parser) se prueba en el Mac sin iPhone: `./probar.sh`.

## Avisos

- **`herramientas/abrir-cert.py`** es una utilidad de escritorio (lector PC/SC) para abrir el
  certificado de autenticación del propio documento verificando el PIN. Hace **un solo
  intento** y se detiene; un error consume un intento (recuperable con el PUK). Úsala solo
  sobre tu propia cédula, con el PUK a mano. No contiene ningún PIN — se pide en ejecución.
- **La instrumentación de depuración** (traza vía `OSLogPreferences`, volcado de grupos)
  **no debe llegar a producción**: escribe la llave del documento en el log del sistema.
- Leer la cédula de un tercero implica sus datos personales: requiere su **consentimiento**
  (Ley 172-13) y borrar los volcados al terminar.

## Autoría y alcance

© 2026 **Pablo Holguín**. Trabajo de reingeniería e investigación independiente sobre la
nueva cédula dominicana. No representa a la Junta Central Electoral ni a ninguna institución.
