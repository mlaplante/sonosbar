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
            let body = String(data: data, encoding: .utf8) ?? "(non-utf8)"
            // First: structured parse (case-sensitive on element names).
            // If that misses, dump the raw payload so we can see the real
            // element names / namespace prefixes the firmware uses.
            if let root = try? XMLNode.parse(data) {
                let accounts = root.descendants(named: "Account")
                let lowercase = root.descendants(named: "account")
                out += "Parsed <Account> count: \(accounts.count), <account> count: \(lowercase.count)\n"
                let all = accounts.isEmpty ? lowercase : accounts
                for acct in all {
                    let type = acct.attributes["Type"] ?? acct.attributes["type"] ?? "?"
                    let serial = acct.attributes["SerialNum"] ?? "?"
                    let active = acct.attributes["IsSignedIn"] ?? acct.attributes["Active"] ?? "?"
                    let un = acct.first("UN")?.trimmed ?? acct.first("un")?.trimmed ?? ""
                    let nn = acct.first("NN")?.trimmed ?? acct.first("nn")?.trimmed ?? ""
                    let md = acct.first("MD")?.trimmed ?? acct.first("md")?.trimmed ?? ""
                    out += "  Type \(type)  Serial \(serial)  Active \(active)\n"
                    out += "      UN: \(un.isEmpty ? "(empty)" : un)  NN: \(nn.isEmpty ? "(empty)" : nn)  MD: \(md.isEmpty ? "(empty)" : md)\n"
                }
            }
            out += "\nRaw body (\(data.count) bytes, first 1500 chars):\n"
            out += String(body.prefix(1500))
            out += "\n"
        } catch {
            out += "ERROR: \(error.localizedDescription)\n"
        }

        // The speaker can proxy SMAPI calls through its own ContentDirectory.
        // ObjectID="0" returns the root container hierarchy, which includes
        // music services as children. Drilling into the service's subtree
        // lets us browse and (depending on the service) search WITHOUT
        // managing our own session token. This is the architecture node-sonos
        // and SoCo use for music-service browsing.
        out += "\n=== ContentDirectory.Browse ObjectID=\"0\" (root) ===\n"
        await dumpBrowse(objectID: "0", on: player, into: &out, limit: 50)

        // The previous root browse revealed the real container IDs:
        // A: (library), S: (services), SQ: (saved queues), R: (radio),
        // FV: (favorites), Q: (queue). Drill into S: to see linked
        // services. For each direct child, drill one more level so we
        // can see Amazon Music's top-level categories (if it's there).
        out += "\n=== ContentDirectory.Browse ObjectID=\"S:\" (music services root) ===\n"
        let serviceChildren = await collectChildContainerIDs(
            objectID: "S:", on: player, into: &out, limit: 50
        )

        for childID in serviceChildren.prefix(20) {
            out += "\n--- drill into \(childID) ---\n"
            _ = await collectChildContainerIDs(
                objectID: childID, on: player, into: &out, limit: 15
            )
        }

        // Also peek at R: (radio / TuneIn) for comparison — Amazon Music
        // stations sometimes route through here on older firmware.
        out += "\n=== ContentDirectory.Browse ObjectID=\"R:\" (radio root) ===\n"
        _ = await collectChildContainerIDs(
            objectID: "R:", on: player, into: &out, limit: 15
        )

        out += "\n=== Interpretation hints ===\n"
        _ = "" // separator
        out += "- Match an Account's Type to a Service's Id to know which accounts are linked.\n"
        out += "- Auth=\"DeviceLink\" or \"AppLink\" means OAuth via Sonos; we mint a SessionId\n"
        out += "  via GetSessionId(ServiceId, Username) then call the service's SecureUri with\n"
        out += "  a SOAP <credentials> header. Auth=\"Anonymous\" means no token needed.\n"
        out += "- Capabilities is a bitmask. 0x1 = search, 0x10 = trackId-based, etc.\n"
        out += "- If Amazon Music's Service entry isn't here, the account isn't linked on\n"
        out += "  this player — add it in the Sonos app first.\n"
        return out
    }

    /// Same as dumpBrowse but also returns the IDs of child containers
    /// so the caller can drill deeper. Highlights any title containing
    /// "amazon" with a star so it's easy to spot in the report.
    @discardableResult
    private func collectChildContainerIDs(
        objectID: String,
        on player: DiscoveredPlayer,
        into out: inout String,
        limit: Int
    ) async -> [String] {
        var childIDs: [String] = []
        do {
            let response = try await client.send(
                action: "Browse",
                service: .contentDirectory,
                arguments: [
                    ("ObjectID", objectID),
                    ("BrowseFlag", "BrowseDirectChildren"),
                    ("Filter", "*"),
                    ("StartingIndex", "0"),
                    ("RequestedCount", "\(limit)"),
                    ("SortCriteria", "")
                ],
                to: player
            )
            let totalMatches = response.descendants(named: "TotalMatches").first?.trimmed ?? "?"
            let numberReturned = response.descendants(named: "NumberReturned").first?.trimmed ?? "?"
            out += "  TotalMatches: \(totalMatches), NumberReturned: \(numberReturned)\n"
            guard let didlText = response.descendants(named: "Result").first?.trimmed,
                  !didlText.isEmpty,
                  let didl = try? XMLNode.parse(didlText) else {
                out += "  (empty or unparseable Result)\n"
                return []
            }
            for c in didl.descendants(named: "container") {
                let id = c.attributes["id"] ?? "?"
                let title = c.descendants(named: "title").first?.trimmed ?? ""
                let cls = c.descendants(named: "class").first?.trimmed ?? ""
                let marker = title.localizedCaseInsensitiveContains("amazon") ? "★" : " "
                out += "  \(marker) C  id=\(id)  title=\(title)  class=\(cls)\n"
                childIDs.append(id)
            }
            for i in didl.descendants(named: "item").prefix(limit) {
                let id = i.attributes["id"] ?? "?"
                let title = i.descendants(named: "title").first?.trimmed ?? ""
                let res = i.first("res")?.trimmed ?? ""
                let marker = title.localizedCaseInsensitiveContains("amazon") ? "★" : " "
                out += "  \(marker) I  id=\(id)  title=\(title)\n"
                if !res.isEmpty { out += "     res: \(res)\n" }
            }
        } catch {
            out += "  ERROR: \(error.localizedDescription)\n"
        }
        return childIDs
    }

    /// Helper: Browse a ContentDirectory ObjectID and dump the parsed
    /// title/class/uri of each direct child, plus a count and the raw
    /// DIDL on parse failure. Used by the probe to understand the
    /// speaker's content hierarchy without committing to a domain model.
    private func dumpBrowse(
        objectID: String,
        on player: DiscoveredPlayer,
        into out: inout String,
        limit: Int
    ) async {
        do {
            let response = try await client.send(
                action: "Browse",
                service: .contentDirectory,
                arguments: [
                    ("ObjectID", objectID),
                    ("BrowseFlag", "BrowseDirectChildren"),
                    ("Filter", "*"),
                    ("StartingIndex", "0"),
                    ("RequestedCount", "\(limit)"),
                    ("SortCriteria", "")
                ],
                to: player
            )
            let totalMatches = response.descendants(named: "TotalMatches").first?.trimmed ?? "?"
            let numberReturned = response.descendants(named: "NumberReturned").first?.trimmed ?? "?"
            out += "TotalMatches: \(totalMatches), NumberReturned: \(numberReturned)\n"
            guard let didlText = response.descendants(named: "Result").first?.trimmed,
                  !didlText.isEmpty else {
                out += "(empty Result)\n"
                return
            }
            guard let didl = try? XMLNode.parse(didlText) else {
                out += "(could not parse DIDL)\nRaw (first 600 chars):\n\(didlText.prefix(600))\n"
                return
            }
            let containers = didl.descendants(named: "container")
            let items = didl.descendants(named: "item")
            out += "Containers: \(containers.count), Items: \(items.count)\n"
            for c in containers.prefix(limit) {
                let id = c.attributes["id"] ?? "?"
                let parent = c.attributes["parentID"] ?? "?"
                let title = c.descendants(named: "title").first?.trimmed ?? ""
                let cls = c.descendants(named: "class").first?.trimmed ?? ""
                out += "  C  id=\(id)  parent=\(parent)  class=\(cls)\n     title: \(title)\n"
            }
            for i in items.prefix(limit) {
                let id = i.attributes["id"] ?? "?"
                let title = i.descendants(named: "title").first?.trimmed ?? ""
                let res = i.first("res")?.trimmed ?? ""
                out += "  I  id=\(id)\n     title: \(title)\n     res:   \(res)\n"
            }
        } catch {
            out += "ERROR: \(error.localizedDescription)\n"
        }
    }
}
