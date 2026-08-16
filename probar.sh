#!/bin/bash
# Comprueba en el Mac la lógica pura: derivación de la llave BAC y parser de la MRZ.
# No necesita iPhone, ni firma, ni Xcode abierto — solo swiftc.
set -e
cd "$(dirname "$0")"
TMP=$(mktemp -d)
swiftc Sources/LlaveMRZ.swift Sources/AnalizadorMRZ.swift Pruebas/main.swift -o "$TMP/pruebas"
"$TMP/pruebas"
