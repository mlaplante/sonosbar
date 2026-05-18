//
//  MusicServicesProbe.swift
//  SonosBar
//
//  Spike for chunk B (Amazon Music SMAPI search). Before we commit to a
//  search architecture we need to see what the actual speaker exposes
//  for music services on this household. Two data sources:
//
//    1. SOAP: MusicServices.ListAvailableServices — every music service
//       the speaker knows about (linked or not), plus per-service
//       endpoints, auth policies, capabilities.
//    2. HTTP: GET /status/accounts on port 1400 — every account the
//       household has linked, including the encrypted username, account
//       Type (numeric service ID), SerialNum, and Nickname.
//
//  This file does no parsing into domain types. It returns the raw
//  response bodies + a short structured summary so the user and the
//  developer can read them in the Diagnostics view and decide what
//  Amazon Music's service ID/auth model looks like on THIS household.
//

import Foundation

struct MusicServicesProbe {

    private let client: SOAPClient

    init(client: SOAPClient = SOAPClient()) {
        self.client = client
    }

    /// Runs ListAvailableServices + /status/accounts against the player
    /// and returns a single human-readable report.
    func probe(on player: DiscoveredPlayer) async -> String {
        var out = "SonosBar Music Services Probe\n"
        out += "Player: \(player.zoneName) @ \(player.baseURL.absoluteString)\n"
        out += "Time:   \(ISO8601DateFormatter().string(from: Date()))\n"
        out += String(repeating: "─", count: 60) + "\n\n"

        out += "=== ListAvailableServices (SOAP) ===\n"
        do {
            let response = try await client.send(
                action: "ListAvailableServices",
                service: .musicServices,
                arguments: [],
                to: player
            )
            // Response wraps three children: AvailableServiceDescriptorList
            // (escaped XML), AvailableServiceTypeList (comma-sep ID:type),
            // AvailableServiceListVersion.
            let descriptor = response.descendants(named: "AvailableServiceDescriptorList").first?.trimmed ?? ""
            let typeList = response.descendants(named: "AvailableServiceTypeList").first?.trimmed ?? ""
            let version = response.descendants(named: "AvailableServiceListVersion").first?.trimmed ?? ""

            out += "Version: \(version)\n"
            out += "ServiceTypeList (id:type):\n  \(typeList)\n\n"

            if !descriptor.isEmpty,
               let descriptorRoot = try? XMLNode.parse(descriptor) {
                let services = descriptorRoot.descendants(named: "Service")
                out += "Services (\(services.count)):\n"
                for svc in services {
                    let id = svc.attributes["Id"] ?? "?"
                    let name = svc.attributes["Name"] ?? "?"
                    let uri = svc.attributes["Uri"] ?? ""
                    let secureUri = svc.attributes["SecureUri"] ?? ""
                    let containerType = svc.attributes["ContainerType"] ?? ""
                    let capabilities = svc.attributes["Capabilities"] ?? ""
                    let policy = svc.first("Policy")
                    let auth = policy?.attributes["Auth"] ?? "?"
                    let pollInterval = policy?.attributes["PollInterval"] ?? "-"

                    let isAmazon = name.localizedCaseInsensitiveContains("amazon")
                    let marker = isAmazon ? "★ " : "  "
                    out += "\(marker)[\(id)] \(name)\n"
                    out += "      Auth: \(auth)  Container: \(containerType)  Capabilities: \(capabilities)  PollInterval: \(pollInterval)\n"
                    if !secureUri.isEmpty {
                        out += "      SecureUri: \(secureUri)\n"
                    } else if !uri.isEmpty {
                        out += "      Uri:       \(uri)\n"
                    }
                }
            } else {
                out += "(could not parse AvailableServiceDescriptorList)\n"
                out += "Raw:\n\(descriptor.prefix(800))\n"
            }
        } catch {
            out += "ERROR: \(error.localizedDescription)\n"
        }

        out += "\n=== /status/accounts (HTTP GET) ===\n"
        let accountsURL = player.baseURL.appendingPathComponent("status/accounts")
        do {
            let (data, response) = try await URLSession.shared.data(from: accountsURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                out += "HTTP \(http.statusCode)\n"
            }
            if let root = try? XMLNode.parse(data) {
                let accounts = root.descendants(named: "Account")
                out += "Accounts (\(accounts.count)):\n"
                for acct in accounts {
                    let type = acct.attributes["Type"] ?? "?"
                    let serial = acct.attributes["SerialNum"] ?? "?"
                    let active = acct.attributes["IsSignedIn"] ?? acct.attributes["Active"] ?? "?"
                    let un = acct.first("UN")?.trimmed ?? ""
                    let nn = acct.first("NN")?.trimmed ?? ""
                    let md = acct.first("MD")?.trimmed ?? ""
                    let oadid = acct.first("OADevID")?.trimmed ?? ""

                    out += "  Type \(type)  Serial \(serial)  Active \(active)\n"
                    out += "      UN: \(un.isEmpty ? "(empty)" : un)\n"
                    out += "      NN: \(nn.isEmpty ? "(empty)" : nn)\n"
                    if !md.isEmpty { out += "      MD: \(md)\n" }
                    if !oadid.isEmpty { out += "      OADevID: \(oadid)\n" }
                }
            } else {
                let body = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                out += "(could not parse XML)\nRaw (first 800 chars):\n\(body.prefix(800))\n"
            }
        } catch {
            out += "ERROR: \(error.localizedDescription)\n"
        }

        out += "\n=== Interpretation hints ===\n"
        out += "- Match an Account's Type to a Service's Id to know which accounts are linked.\n"
        out += "- Auth=\"DeviceLink\" or \"AppLink\" means OAuth via Sonos; we mint a SessionId\n"
        out += "  via GetSessionId(ServiceId, Username) then call the service's SecureUri with\n"
        out += "  a SOAP <credentials> header. Auth=\"Anonymous\" means no token needed.\n"
        out += "- Capabilities is a bitmask. 0x1 = search, 0x10 = trackId-based, etc.\n"
        out += "- If Amazon Music's Service entry isn't here, the account isn't linked on\n"
        out += "  this player — add it in the Sonos app first.\n"
        return out
    }
}
