//
//  UpdateSignature.swift
//  SonosBar
//
//  Ed25519 verification of the release manifest. The app is distributed
//  unsigned (ad-hoc), so this signature is the ENTIRE update-integrity
//  guarantee — the matching private key exists only as a CI secret.
//  Verification runs over the raw downloaded bytes BEFORE any JSON
//  parsing; nothing from an unverified manifest is ever trusted.
//  scripts/sign-update.swift is the producing side of this format.
//

import Foundation
import CryptoKit

enum UpdateSignature {

    /// Returns true only if `signatureBase64` is a valid Ed25519 signature
    /// over `manifestBytes` by the key `publicKeyBase64`. All failures —
    /// bad base64, wrong key length, mismatch — are equal: false.
    static func verify(manifestBytes: Data,
                       signatureBase64: String,
                       publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let sigData = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return publicKey.isValidSignature(sigData, for: manifestBytes)
    }
}
