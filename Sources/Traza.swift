import Foundation
import OSLog

/// Recoge la traza que NFCPassportReader escribe con `os.Logger` y la deja a mano:
/// visible dentro de la app y volcada a un archivo que se puede sacar del iPhone.
///
/// La librería registra la derivación BAC completa en nivel `debug` (llave MRZ, Kseed,
/// Kenc/Kmac, RND.ICC/RND.IFD y la respuesta de cada APDU). Para que eso sea legible
/// hacen falta dos cosas, ambas en el Info.plist bajo `OSLogPreferences`:
///   1. persistir el nivel `Debug` — si no, los mensajes se descartan;
///   2. `Enable-Private-Data` — si no, cada valor interpolado sale como `<private>`.
///
/// ⚠️ Eso significa que la llave de acceso al documento acaba escrita en el log del
/// sistema. Es aceptable depurando con la cédula de prueba; **hay que quitarlo antes de
/// producción** (ver la lista de la Fase 4 en el README).
@available(iOS 15.0, *)
enum Traza {

    static let nombreArchivo = "traza-nfc.txt"

    /// Entradas de nuestro subsistema desde un instante dado.
    static func recoger(desde inicio: Date) -> [String] {
        guard let almacen = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return ["(no se pudo abrir OSLogStore)"]
        }
        let subsistema = Bundle.main.bundleIdentifier ?? ""
        let posicion = almacen.position(date: inicio)

        guard let entradas = try? almacen.getEntries(at: posicion) else {
            return ["(no se pudieron leer las entradas del log)"]
        }

        let hora = DateFormatter()
        hora.dateFormat = "HH:mm:ss.SSS"

        var lineas: [String] = []
        for caso in entradas {
            guard let entrada = caso as? OSLogEntryLog,
                  entrada.subsystem == subsistema else { continue }
            lineas.append("\(hora.string(from: entrada.date)) [\(entrada.category)] \(entrada.composedMessage)")
        }
        return lineas.isEmpty
            ? ["(sin entradas: ¿falta OSLogPreferences en el Info.plist?)"]
            : lineas
    }

    /// Añade el bloque al archivo de traza, conservando los intentos anteriores.
    @discardableResult
    static func guardar(_ lineas: [String], cabecera: String) -> URL? {
        guard let carpeta = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let destino = carpeta.appendingPathComponent(nombreArchivo)

        let sello = ISO8601DateFormatter().string(from: Date())
        let bloque = "\n===== \(sello) · \(cabecera) =====\n"
            + lineas.joined(separator: "\n") + "\n"

        if let datos = bloque.data(using: .utf8) {
            if let manejador = try? FileHandle(forWritingTo: destino) {
                defer { try? manejador.close() }
                _ = try? manejador.seekToEnd()
                try? manejador.write(contentsOf: datos)
            } else {
                try? datos.write(to: destino)
            }
        }
        return destino
    }
}
