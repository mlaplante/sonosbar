#!/usr/bin/env swift
// sign-update.swift
//
// CI-side signer for the release manifest. Reads the private key from
// the UPDATE_ED_PRIVATE_KEY environment variable (never argv — argv is
// visible in process listings) and signs the EXACT bytes of the manifest
// file. The verifier (UpdateSignature.swift) checks those same raw
// bytes, so the manifest must not be reformatted after signing.
//
//   UPDATE_ED_PRIVATE_KEY=<base64> swift scripts/sign-update.swift dist/appcast.json
//
// Writes dist/appcast.json.sig (base64 text). Exits non-zero on any problem.

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <manifest-path>\n".utf8))
    exit(64)
}
let manifestPath = CommandLine.arguments[1]
guard let keyBase64 = ProcessInfo.processInfo.environment["UPDATE_ED_PRIVATE_KEY"],
      !keyBase64.isEmpty else {
    FileHandle.standardError.write(Data("UPDATE_ED_PRIVATE_KEY is not set\n".utf8))
    exit(64)
}
guard let keyData = Data(base64Encoded: keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("UPDATE_ED_PRIVATE_KEY is not a valid Ed25519 key\n".utf8))
    exit(65)
}
guard let manifest = FileManager.default.contents(atPath: manifestPath) else {
    FileHandle.standardError.write(Data("cannot read \(manifestPath)\n".utf8))
    exit(66)
}
let signature = try key.signature(for: manifest)
try signature.base64EncodedString().write(toFile: manifestPath + ".sig",
                                          atomically: true, encoding: .utf8)
print("signed \(manifestPath) -> \(manifestPath).sig")
