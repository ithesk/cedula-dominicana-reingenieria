#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Abre el CERTIFICADO DE AUTENTICACIÓN (EF 0101) del applet CitizenID de la cédula
dominicana, verificando el PIN. Lo ejecutas TÚ, en TU lector, con TU cédula.

⚠️  RIESGO — LÉELO:
    Si el PIN o su codificación no son correctos, se CONSUME UN INTENTO. Agotar los
    intentos bloquea el PIN (se recupera con el PUK). Esta tarjeta OCULTA el contador,
    así que no se sabe cuántos quedan. Por eso este script:
      · hace UN SOLO intento y se detiene, pase lo que pase,
      · NUNCA reintenta con otra codificación ni con otra referencia,
      · NUNCA toca el PUK.
    Ten el PUK a mano antes de ejecutar.

    Esto abre solo el cert de AUTENTICACIÓN. La firma cualificada NO está en el chip
    todavía (el servicio de la JCE no está lanzado).

Requisitos:  pip3 install pyscard   +   un lector PC/SC NFC (ACR122U o similar).
Uso:         python3 abrir-cert.py
"""

import sys
import getpass

try:
    from smartcard.System import readers
    from smartcard.util import toHexString
except ImportError:
    sys.exit("Falta pyscard.  Instala con:  pip3 install pyscard")

AID_CITIZENID = [0xD2, 0x76, 0x00, 0x00, 0x98, 0x43, 0x69, 0x74, 0x69, 0x7A, 0x65, 0x6E, 0x49, 0x44]
REF_PIN = 0x01            # referencia más probable del PIN de autenticación
EF_CERT = [0x01, 0x01]    # fichero del certificado de autenticación


def sw(resp_sw1, resp_sw2):
    return (resp_sw1 << 8) | resp_sw2


def enviar(conn, apdu, etiqueta):
    data, sw1, sw2 = conn.transmit(apdu)
    print(f"  {etiqueta:<28} -> {sw1:02X}{sw2:02X}")
    return data, sw1, sw2


def main():
    print(__doc__)

    # --- Confirmación consciente (evita ejecuciones por accidente) ---
    print("Vas a hacer UN intento de PIN. Si falla, se consume y el script para.")
    if input('Escribe exactamente  ABRIR  para continuar: ').strip() != "ABRIR":
        sys.exit("Cancelado. No se envió nada.")
    if input('¿Tienes el PUK a mano por si se bloquea? (si/no): ').strip().lower() != "si":
        sys.exit("Consigue el PUK primero. No se envió nada.")

    # --- Lector ---
    lista = readers()
    if not lista:
        sys.exit("No hay lector PC/SC. Conecta el ACR122U (u otro) y apoya la cédula.")
    conn = lista[0].createConnection()
    conn.connect()
    print(f"\nLector: {lista[0]}")

    # --- Seleccionar CitizenID ---
    _, s1, s2 = enviar(conn, [0x00, 0xA4, 0x04, 0x00, len(AID_CITIZENID)] + AID_CITIZENID + [0x00],
                       "SELECT CitizenID")
    if sw(s1, s2) != 0x9000:
        sys.exit("No se pudo seleccionar CitizenID. Aborto sin tocar el PIN.")

    # --- PIN (no se guarda, no se imprime) ---
    pin = getpass.getpass("PIN (no se mostrará): ").strip()
    if not pin.isdigit():
        sys.exit("El PIN debe ser numérico. No se envió nada.")
    pin_ascii = [ord(c) for c in pin]     # codificación ASCII (0->0x30, 2->0x32, ...)

    print("\n>>> ENVIANDO EL ÚNICO INTENTO (referencia 01, ASCII) <<<")
    _, s1, s2 = enviar(conn, [0x00, 0x20, 0x00, REF_PIN, len(pin_ascii)] + pin_ascii,
                       "VERIFY PIN")
    estado = sw(s1, s2)

    if estado == 0x9000:
        print("\n✅ PIN CORRECTO. Leyendo el certificado…")
        leer_certificado(conn)
    elif s1 == 0x6A and s2 in (0x88, 0x86):
        print("\nℹ️  Referencia 01 no era el PIN (6A88) — NO se descontó intento.")
        print("    La referencia 02 sería segura de probar, pero eso es OTRA decisión.")
    elif s1 == 0x63:
        print(f"\n❌ PIN incorrecto o codificación equivocada ({s1:02X}{s2:02X}).")
        print("   SE CONSUMIÓ UN INTENTO. EL SCRIPT PARA AQUÍ — no reintenta.")
        print("   No pruebes BCD ni la ref 02 seguidas: es la espiral que bloquea.")
    elif estado == 0x6983:
        print("\n⛔ PIN BLOQUEADO (6983). Haría falta el PUK para desbloquear.")
    else:
        print(f"\n⚠️  Respuesta inesperada: {s1:02X}{s2:02X}. El script para por prudencia.")


def leer_certificado(conn):
    _, s1, s2 = enviar(conn, [0x00, 0xA4, 0x02, 0x0C, 0x02] + EF_CERT, "SELECT EF 0101")
    if sw(s1, s2) != 0x9000:
        print("  No se pudo seleccionar el fichero del cert.")
        return
    datos = []
    offset = 0
    while True:
        p1, p2 = (offset >> 8) & 0xFF, offset & 0xFF
        bloque, s1, s2 = conn.transmit([0x00, 0xB0, p1, p2, 0x00])
        if s1 in (0x62, 0x63) or s1 == 0x90:
            datos += bloque
            if len(bloque) == 0 or s1 != 0x90:
                break
            offset += len(bloque)
        elif s1 == 0x6C:                      # longitud correcta indicada
            bloque, s1, s2 = conn.transmit([0x00, 0xB0, p1, p2, s2])
            datos += bloque
            break
        else:
            break
    if not datos:
        print("  El fichero vino vacío.")
        return
    with open("cert-autenticacion.der", "wb") as f:
        f.write(bytes(datos))
    print(f"  Guardado: cert-autenticacion.der ({len(datos)} bytes)")
    print("  Decodifícalo con:")
    print("     openssl x509 -inform DER -in cert-autenticacion.der -noout -text")
    print("  (o pásame el hex y te lo decodifico yo)")
    print("  HEX:", toHexString(datos))


if __name__ == "__main__":
    main()
