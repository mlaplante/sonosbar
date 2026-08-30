#!/usr/bin/env swift
// generate-update-keys.swift
//
// One-time generation of the SonosBar update-signing keypair. Run at a
// keyboard, never in CI:
//
//   swift scripts/generate-update-keys.swift
//
// Then:
//   * PUBLIC  -> Info.plist, value of SBUpdatePublicKey
//   * PRIVATE -> GitHub repo secret UPDATE_ED_PRIVATE_KEY, plus a durable
//                offline backup. Losing it strands every installed client
//                on manual updates; leaking it hands code execution to
//                whoever holds it. It must never touch the repo.

import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
print("PUBLIC:  \(key.publicKey.rawRepresentation.base64EncodedString())")
print("PRIVATE: \(key.rawRepresentation.base64EncodedString())")
print("")
print("Public key  -> SBUpdatePublicKey in SonosBar/Resources/Info.plist")
print("Private key -> GitHub secret UPDATE_ED_PRIVATE_KEY (and an offline backup)")
