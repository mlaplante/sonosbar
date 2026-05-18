//
//  SSDPDiscovery.swift
//  SonosBar
//
//  SSDP M-SEARCH discovery for Sonos ZonePlayer devices.
//
//  Protocol summary (per the UPnP Device Architecture spec):
//    Client sends a UDP packet to multicast group 239.255.255.250 port 1900
//    containing a specific HTTP-shaped header. Devices that match the
//    search target (ST) respond with a unicast UDP packet pointing at
//    their device description XML.
//
//    M-SEARCH * HTTP/1.1
//    HOST: 239.255.255.250:1900
//    MAN: "ssdp:discover"
//    MX: 1
//    ST: urn:schemas-upnp-org:device:ZonePlayer:1
//
//  We use the ZonePlayer ST because that's what the actual Sonos device
//  registers under at the root level. urn:schemas-upnp-org:device:MediaRenderer:1
//  also matches but returns the embedded MediaRenderer sub-device,
//  which complicates the LOCATION parsing.
//
//  Sandbox / entitlements: SonosBar ships unsandboxed (direct .dmg
//  distribution), so multicast UDP just works. If we ever target the
//  App Store this becomes a multi-month entitlement application —
//  see chunk 1's brainstorm doc.
//

import Foundation
import Network

actor SSDPDiscovery {

    // MARK: - Public API

    /// Performs a single discovery sweep.
    ///
    /// Sends a few M-SEARCH packets (multicast is lossy, hence retry),
    /// listens for responses for `timeout` seconds, then returns the
    /// unique set of Sonos players found.
    ///
    /// Subsequent calls are independent — there's no long-lived listener.
    /// The domain layer (chunk 4) decides how often to poll.
    func search(timeout: Duration = .seconds(3)) async -> [DiscoveredPlayer] {
        Log.discovery.info("Starting SSDP search (timeout: \(timeout.components.seconds)s)")

        // Collect raw LOCATION URLs first; resolving them to players
        // happens in a second pass so we can de-dupe by URL before
        // making N concurrent HTTP requests.
        let locations: Set<URL>
        do {
            locations = try await collectLocations(timeout: timeout)
        } catch {
            Log.discovery.error("SSDP listen failed: \(error.localizedDescription)")
            return []
        }

        Log.discovery.info("SSDP collected \(locations.count) unique LOCATION URLs")

        // Fetch device descriptions in parallel. One bad/unreachable
        // device shouldn't block the others.
        let players = await withTaskGroup(of: DiscoveredPlayer?.self) { group in
            for url in locations {
                group.addTask {
                    await Self.fetchPlayer(at: url)
                }
            }
            var found: [DiscoveredPlayer] = []
            for await player in group {
                if let player { found.append(player) }
            }
            return found
        }

        // De-dupe by UUID. Sonos devices can advertise themselves multiple
        // times during the M-SEARCH window, so the same player may show
        // up at two slightly different URLs.
        let unique = Dictionary(grouping: players, by: \.uuid)
            .compactMap { $0.value.first }

        Log.discovery.info("SSDP discovered \(unique.count) Sonos players")
        return unique
    }

    // MARK: - Multicast send + listen

    private static let ssdpHost: NWEndpoint.Host = "239.255.255.250"
    private static let ssdpPort: NWEndpoint.Port = 1900

    /// Sonos search target. ZonePlayer is the top-level UPnP device type
    /// every Sonos product registers as.
    private static let searchTarget = "urn:schemas-upnp-org:device:ZonePlayer:1"

    private static let mSearchPayload: Data = {
        // The blank trailing line and CRLFs matter — SSDP is HTTP-shaped
        // and most stacks require the terminator to be exactly `\r\n\r\n`.
        let body = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 1\r
        ST: \(searchTarget)\r
        \r

        """
        return Data(body.utf8)
    }()

    /// Sends M-SEARCH and collects LOCATION headers from responses.
    private func collectLocations(timeout: Duration) async throws -> Set<URL> {

        // We use NWConnectionGroup with a multicast descriptor so we can
        // both send to the multicast group and receive unicast responses
        // on the same socket. NWConnection (singular) is one-to-one and
        // can't receive the unicast replies that come back from multiple
        // devices.
        let multicast = try NWMulticastGroup(for: [.hostPort(host: Self.ssdpHost, port: Self.ssdpPort)])
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let group = NWConnectionGroup(with: multicast, using: params)

        // Use a continuation-bridged stream so we can `for await` the
        // responses with a clean timeout.
        let (stream, continuation) = AsyncStream<URL>.makeStream()

        group.setReceiveHandler(maximumMessageSize: 65535, rejectOversizedMessages: true) { _, content, _ in
            guard let data = content,
                  let response = String(data: data, encoding: .utf8) else { return }
            if let url = Self.extractLocation(from: response) {
                continuation.yield(url)
            }
        }

        group.stateUpdateHandler = { state in
            Log.discovery.debug("SSDP group state: \(String(describing: state))")
        }

        group.start(queue: .global(qos: .userInitiated))

        // Send the M-SEARCH a few times. UDP multicast is best-effort and
        // some routers drop the first packet while AP roaming kicks in.
        for attempt in 1...3 {
            group.send(content: Self.mSearchPayload) { error in
                if let error {
                    Log.discovery.error("M-SEARCH send #\(attempt) failed: \(error.localizedDescription)")
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Drain responses for `timeout` then tear down.
        var locations: Set<URL> = []
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        for await url in stream {
            locations.insert(url)
        }
        deadline.cancel()
        group.cancel()

        return locations
    }

    /// Pulls the LOCATION: header value from an SSDP response.
    private static func extractLocation(from response: String) -> URL? {
        for line in response.split(separator: "\r\n", omittingEmptySubsequences: true) {
            // Headers are case-insensitive per the SSDP spec, but in
            // practice Sonos always sends "LOCATION:" uppercase.
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                let raw = line.dropFirst("location:".count)
                    .trimmingCharacters(in: .whitespaces)
                return URL(string: raw)
            }
        }
        return nil
    }

    // MARK: - Device description fetch + parse

    /// Hits the device description endpoint and turns it into a
    /// DiscoveredPlayer. Returns nil if the URL isn't actually a Sonos
    /// device (e.g. some other UPnP gear on the network) or if the
    /// fetch fails.
    private static func fetchPlayer(at url: URL) async -> DiscoveredPlayer? {

        // Sonos description URLs are always /xml/device_description.xml
        // on port 1400. We don't trust the LOCATION's path verbatim
        // because some Sonos firmware revisions have advertised
        // alternate paths that we don't parse correctly.
        guard let host = url.host, let port = url.port else {
            Log.discovery.debug("Skipping LOCATION with no host/port: \(url)")
            return nil
        }
        let descURL = URL(string: "http://\(host):\(port)/xml/device_description.xml")!

        do {
            // 2-second timeout per device. If a speaker is on the LAN but
            // unreachable (sleeping, wifi flaky) we don't want to hold up
            // the rest of the sweep.
            var request = URLRequest(url: descURL, timeoutInterval: 2)
            request.httpMethod = "GET"

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            return try parseDeviceDescription(data, host: host, port: port)
        } catch {
            Log.discovery.debug("Description fetch failed for \(descURL): \(error.localizedDescription)")
            return nil
        }
    }

    /// Parses the relevant fields out of /xml/device_description.xml.
    ///
    /// The doc looks like:
    ///   <root>
    ///     <device>
    ///       <UDN>uuid:RINCON_5CAAFD123456789</UDN>
    ///       <modelName>Sonos One</modelName>
    ///       <roomName>Kitchen</roomName>
    ///       <displayName>One</displayName>
    ///       <householdId>Sonos_xxxxxxxx</householdId>
    ///       ...
    ///     </device>
    ///   </root>
    private static func parseDeviceDescription(_ data: Data, host: String, port: Int) throws -> DiscoveredPlayer? {
        let root = try XMLNode.parse(data)

        // Walk to the <device> element; SSDP roots have it as a direct child.
        guard let device = root.descendants(named: "device").first else {
            return nil
        }

        // UDN is "uuid:RINCON_..." — we strip the prefix.
        guard let udn = device.first("UDN")?.trimmed else { return nil }
        let uuid = udn.hasPrefix("uuid:") ? String(udn.dropFirst("uuid:".count)) : udn

        // Sanity check: must look like a Sonos UUID. This filters out
        // non-Sonos UPnP devices (smart TVs, printers) that respond to
        // a broad ST. Sonos UUIDs always start with RINCON_.
        guard uuid.hasPrefix("RINCON_") else {
            Log.discovery.debug("Skipping non-Sonos UPnP device with UDN \(udn)")
            return nil
        }

        let model = device.first("modelName")?.trimmed ?? "Sonos"
        let zoneName = device.first("roomName")?.trimmed ?? "Unnamed"
        let household = device.first("householdId")?.trimmed

        return DiscoveredPlayer(
            uuid: uuid,
            host: host,
            port: port,
            model: model,
            zoneName: zoneName,
            household: household
        )
    }
}
