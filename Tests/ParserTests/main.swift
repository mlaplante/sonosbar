//
//  main.swift — SonosBar parser tests
//
//  A plain executable harness rather than an XCTest target, on purpose:
//  it compiles the REAL production parser sources (see
//  scripts/run-parser-tests.sh) together with this file, so it runs on
//  Command Line Tools-only machines (no XCTest runtime) and in CI alike.
//  Fixtures are sanitized captures from real Sonos speakers.
//
//  Exit code 0 = all assertions passed; 1 = failures (printed).
//

import Foundation
import CryptoKit

var failures = 0
var passes = 0

@MainActor
func expect(_ condition: Bool, _ label: String) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("FAIL: \(label)")
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        passes += 1
    } else {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(actual)")
    }
}

func fixture(_ name: String) -> Data {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else {
        print("FATAL: missing fixture \(name)")
        exit(2)
    }
    return data
}

let baseURL = URL(string: "http://192.0.2.65:1400")!

// MARK: - XMLNode: namespace-prefix-insensitive matching

do {
    let didl = """
    <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
    <item id="1"><dc:title>T</dc:title><upnp:albumArtURI>/getaa?u=x</upnp:albumArtURI><res protocolInfo="p">uri</res></item>
    </DIDL-Lite>
    """
    let root = try XMLNode.parse(didl)
    expect(root.descendants(named: "title").first?.trimmed == "T", "XMLNode matches dc:title by local name")
    expect(root.descendants(named: "dc:title").first != nil, "XMLNode still matches by exact qualified name")
    expect(root.descendants(named: "albumArtURI").first?.trimmed == "/getaa?u=x", "XMLNode matches upnp:albumArtURI by local name")
    expect(root.descendants(named: "item").first?.first("res")?.attributes["protocolInfo"] == "p", "XMLNode reads attributes")
} catch {
    expect(false, "XMLNode parses namespaced DIDL: \(error)")
}

// MARK: - parseDIDLTrack from a real GetPositionInfo capture

do {
    let root = try XMLNode.parse(fixture("position-info.xml"))
    let body = root.descendants(named: "GetPositionInfoResponse").first
    expect(body != nil, "finds u:GetPositionInfoResponse despite prefix")
    let didl = body?.first("TrackMetaData")?.trimmed ?? ""
    let track = SOAPTransport.parseDIDLTrack(fromDIDL: didl, baseURL: baseURL)
    expectEqual(track?.title, "Going Existential In The Rave", "track title")
    expectEqual(track?.artist, "KI/KI", "track artist")
    expectEqual(track?.album, "Going Existential In The Rave", "track album")
    expectEqual(track?.albumArtURL?.absoluteString, "https://m.media-amazon.com/images/I/71rFFDbqW3L.jpg", "album art URL")
    expectEqual(track?.duration, 187, "duration from res attribute (0:03:07)")
    expect(SOAPTransport.parseDIDLTrack(fromDIDL: "NOT_IMPLEMENTED", baseURL: baseURL) == nil, "NOT_IMPLEMENTED metadata yields nil")
    expect(SOAPTransport.parseDIDLTrack(fromDIDL: "", baseURL: baseURL) == nil, "empty metadata yields nil")
} catch {
    expect(false, "position-info fixture parses: \(error)")
}

// MARK: - parseZoneGroups from a real GetZoneGroupState capture

do {
    let envelope = try XMLNode.parse(fixture("zone-group-state.xml"))
    guard let stateText = envelope.descendants(named: "ZoneGroupState").first?.trimmed else {
        expect(false, "ZoneGroupState present"); exit(1)
    }
    let groups = SOAPTransport.parseZoneGroups(from: try XMLNode.parse(stateText))
    expectEqual(groups.count, 2, "two zone groups")

    let kitchen = groups.first { $0.coordinatorUUID == "RINCON_AAAA000000001400" }
    expect(kitchen != nil, "kitchen group found by coordinator UUID")
    expectEqual(kitchen?.members.count, 3, "kitchen group raw member count (incl. bonded satellite)")
    expectEqual(kitchen?.visibleMembers.count, 2, "kitchen group visible member count")
    expectEqual(kitchen?.displayName, "Kitchen + 1", "displayName counts visible zones only")
    expect(kitchen?.members.contains { $0.isInvisible } == true, "bonded satellite carries isInvisible")

    let patio = groups.first { $0.coordinatorUUID == "RINCON_DDDD000000001400" }
    expectEqual(patio?.displayName, "Patio", "standalone group displayName")
    expectEqual(patio?.members.first?.host, "192.0.2.64", "member host parsed from Location")
} catch {
    expect(false, "zone-group-state fixture parses: \(error)")
}

// MARK: - Favorites parsing from a real Browse capture

do {
    let envelope = try XMLNode.parse(fixture("favorites-browse.xml"))
    guard let didlText = envelope.descendants(named: "Result").first?.trimmed else {
        expect(false, "favorites Result present"); exit(1)
    }
    let player = DiscoveredPlayer(uuid: "X", host: "192.0.2.65", port: 1400, model: "Test", zoneName: "Kitchen", household: nil)
    let favorites = SOAPTransport.parseFavorites(from: try XMLNode.parse(didlText), player: player)
    expectEqual(favorites.count, 5, "all five favorites parsed (container ones no longer dropped)")
    expectEqual(favorites.map(\.title).sorted().first, "Discover Sonos Radio", "favorite titles via dc:title")
    expectEqual(favorites.count(where: { $0.isPlayable }), 1, "one favorite has a playable URI in this capture")
    expect(favorites.allSatisfy { !$0.uri.isEmpty }, "every favorite has a unique identifier URI")
    expect(favorites.allSatisfy { $0.metadata.contains("DIDL-Lite") }, "every favorite carries r:resMD DIDL metadata")
    expect(favorites.first { $0.isPlayable }?.uri.hasPrefix("x-sonosapi-radio:") == true, "playable favorite keeps its real res URI")
} catch {
    expect(false, "favorites fixture parses: \(error)")
}

// MARK: - EventParser: AVTransport GENA event carrying the real track DIDL

do {
    let event = try EventParser.avTransport(from: fixture("avtransport-event.xml"))
    expectEqual(event.state, .playing, "event transport state")
    expectEqual(event.currentTrackURI, "x-sonos-http:track123.mp4?sid=201", "event track URI")
    let track = event.trackMetadata.flatMap { SOAPTransport.parseDIDLTrack(fromDIDL: $0, baseURL: baseURL) }
    expectEqual(track?.title, "Going Existential In The Rave", "event DIDL round-trips through parseDIDLTrack")
} catch {
    expect(false, "avtransport event parses: \(error)")
}

// MARK: - EventParser: RenderingControl Master channel only

do {
    let event = try EventParser.renderingControl(from: fixture("rendering-event.xml"))
    expectEqual(event.volume, 27, "Master volume (LF channel ignored)")
    expectEqual(event.muted, false, "Master mute")
} catch {
    expect(false, "rendering event parses: \(error)")
}

// MARK: - Queue item parsing

do {
    let didl = """
    <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
    <item id="Q:0/1"><dc:title>First</dc:title><dc:creator>Artist A</dc:creator><upnp:album>Album A</upnp:album><upnp:albumArtURI>/getaa?u=a</upnp:albumArtURI></item>
    <item id="Q:0/2"><dc:title>Second</dc:title><dc:creator>Artist B</dc:creator><upnp:album>Album B</upnp:album></item>
    </DIDL-Lite>
    """
    let items = SOAPTransport.parseQueueItems(from: try XMLNode.parse(didl), startingAt: 1, baseURL: baseURL)
    expectEqual(items.count, 2, "two queue items")
    expectEqual(items[0].index, 1, "queue indices are 1-based")
    expectEqual(items[0].title, "First", "queue title via dc:title")
    expectEqual(items[0].albumArtURL?.absoluteString, "http://192.0.2.65:1400/getaa?u=a", "queue art resolved against player")
    expectEqual(items[1].albumArtURL, nil, "missing art stays nil")
    let paged = SOAPTransport.parseQueueItems(from: try XMLNode.parse(didl), startingAt: 201, baseURL: baseURL)
    expectEqual(paged[1].index, 202, "paging offsets indices")
} catch {
    expect(false, "queue DIDL parses: \(error)")
}

// MARK: - PlayMode mapping round-trips

for raw in ["NORMAL", "REPEAT_ALL", "REPEAT_ONE", "SHUFFLE_NOREPEAT", "SHUFFLE", "SHUFFLE_REPEAT_ONE"] {
    expectEqual(PlayMode(rawValue: raw).rawValue, raw, "PlayMode round-trip \(raw)")
}
expectEqual(PlayMode(rawValue: "GARBAGE").rawValue, "NORMAL", "unknown PlayMode falls back to NORMAL")
expect(PlayMode(rawValue: "SHUFFLE").shuffle && PlayMode(rawValue: "SHUFFLE").repeatMode == .all,
       "SHUFFLE means shuffle plus repeat-all")

// MARK: - Update version comparison

expect(UpdateChecker.version("0.5.0", isNewerThan: "0.4.0"), "0.5.0 > 0.4.0")
expect(UpdateChecker.version("1.0", isNewerThan: "0.9.9"), "1.0 > 0.9.9")
expect(!UpdateChecker.version("0.4.0", isNewerThan: "0.4.0"), "equal versions are not newer")
expect(!UpdateChecker.version("0.4", isNewerThan: "0.4.0"), "0.4 == 0.4.0")

// MARK: - UpdateManifest strict decoding

let goodManifestJSON = """
{"version":"0.6.0","build":"10",\
"url":"https://github.com/mlaplante/sonosbar/releases/download/v0.6.0/SonosBar-0.6.0.app.zip",\
"sha256":"75a0522babf73807f054bfdfac1b65993788d813821814d88fc3abb896ea9c93",\
"bundleIdentifier":"app.sonosbar.SonosBar","minimumSystemVersion":"26.0",\
"releaseNotesURL":"https://github.com/mlaplante/sonosbar/releases/tag/v0.6.0",\
"pubDate":"2026-08-30T12:00:00Z"}
"""
do {
    let m = try UpdateManifest.decode(Data(goodManifestJSON.utf8))
    expectEqual(m.version, "0.6.0", "manifest version decodes")
    expectEqual(m.bundleIdentifier, "app.sonosbar.SonosBar", "manifest bundle id decodes")
    expectEqual(m.url.host, "github.com", "manifest url decodes")
} catch {
    expect(false, "good manifest decodes: \(error)")
}

// Missing field fails closed.
let missingSha = goodManifestJSON.replacingOccurrences(
    of: "\"sha256\":\"75a0522babf73807f054bfdfac1b65993788d813821814d88fc3abb896ea9c93\",",
    with: "")
expect((try? UpdateManifest.decode(Data(missingSha.utf8))) == nil, "missing sha256 rejected")

// Unknown field fails closed (defense against manifest-format confusion).
let extraField = goodManifestJSON.replacingOccurrences(
    of: "\"version\":\"0.6.0\"",
    with: "\"version\":\"0.6.0\",\"evil\":\"x\"")
expect((try? UpdateManifest.decode(Data(extraField.utf8))) == nil, "unknown field rejected")

// Wrong type fails closed.
let wrongType = goodManifestJSON.replacingOccurrences(
    of: "\"build\":\"10\"", with: "\"build\":10")
expect((try? UpdateManifest.decode(Data(wrongType.utf8))) == nil, "non-string build rejected")

// Not JSON at all.
expect((try? UpdateManifest.decode(Data("<html>".utf8))) == nil, "non-JSON rejected")

// Invalid URL string.
let badURL = goodManifestJSON.replacingOccurrences(
    of: "https://github.com/mlaplante/sonosbar/releases/download/v0.6.0/SonosBar-0.6.0.app.zip",
    with: " ")
expect((try? UpdateManifest.decode(Data(badURL.utf8))) == nil, "unparseable url rejected")

// Scheme rejection: ftp URLs not allowed.
let ftpURL = goodManifestJSON.replacingOccurrences(
    of: "https://github.com/mlaplante/sonosbar/releases/download/v0.6.0/SonosBar-0.6.0.app.zip",
    with: "ftp://evil.example/SonosBar.app.zip")
expect((try? UpdateManifest.decode(Data(ftpURL.utf8))) == nil, "non-http(s) payload url rejected")

// Scheme rejection: file URLs not allowed in releaseNotesURL.
let fileNotesURL = goodManifestJSON.replacingOccurrences(
    of: "https://github.com/mlaplante/sonosbar/releases/tag/v0.6.0",
    with: "file:///etc/passwd")
expect((try? UpdateManifest.decode(Data(fileNotesURL.utf8))) == nil, "file: release notes url rejected")

// MARK: - UpdateSignature Ed25519 verification

let sigTestKey = Curve25519.Signing.PrivateKey()
let sigTestPub = sigTestKey.publicKey.rawRepresentation.base64EncodedString()
let manifestBytes = Data(goodManifestJSON.utf8)
let goodSig = (try? sigTestKey.signature(for: manifestBytes))?.base64EncodedString() ?? ""

expect(UpdateSignature.verify(manifestBytes: manifestBytes,
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub),
       "valid signature verifies")
expect(!UpdateSignature.verify(manifestBytes: manifestBytes + Data("x".utf8),
                               signatureBase64: goodSig,
                               publicKeyBase64: sigTestPub),
       "tampered bytes rejected")
let attackerKey = Curve25519.Signing.PrivateKey()
let attackerSig = (try? attackerKey.signature(for: manifestBytes))?.base64EncodedString() ?? ""
expect(!UpdateSignature.verify(manifestBytes: manifestBytes,
                               signatureBase64: attackerSig,
                               publicKeyBase64: sigTestPub),
       "attacker-signed manifest rejected")
expect(!UpdateSignature.verify(manifestBytes: manifestBytes,
                               signatureBase64: "not base64!!!",
                               publicKeyBase64: sigTestPub),
       "garbage signature rejected")
expect(!UpdateSignature.verify(manifestBytes: manifestBytes,
                               signatureBase64: goodSig,
                               publicKeyBase64: "AAAA"),
       "wrong-length public key rejected")
expect(!UpdateSignature.verify(manifestBytes: manifestBytes,
                               signatureBase64: goodSig,
                               publicKeyBase64: ""),
       "empty public key rejected")
expect(UpdateSignature.verify(manifestBytes: manifestBytes,
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub + "\n"),
       "public key with trailing newline still verifies")

// MARK: - UpdateChecker.evaluate (signed-manifest gate)

expect(UpdateChecker.evaluate(manifestBytes: manifestBytes,
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.5.1")?.version == "0.6.0",
       "evaluate accepts newer signed manifest")
expect(UpdateChecker.evaluate(manifestBytes: manifestBytes,
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.6.0") == nil,
       "evaluate rejects same version")
expect(UpdateChecker.evaluate(manifestBytes: manifestBytes,
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.7.0") == nil,
       "evaluate rejects older manifest (no downgrade)")
expect(UpdateChecker.evaluate(manifestBytes: manifestBytes,
                              signatureBase64: attackerSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.5.1") == nil,
       "evaluate rejects bad signature even when version is newer")
expect(UpdateChecker.evaluate(manifestBytes: Data("{}".utf8),
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.5.1") == nil,
       "evaluate rejects signature/content mismatch")

// A signed-but-undecodable manifest must not look like "verified current":
// evaluate returns nil for it AND for a genuinely-current one — the
// distinction (fallback vs quiet success) lives in checkSignedFeed's
// decode+version re-check, exercised here via its components.
let signedGarbage = Data("{\"garbage\":true}".utf8)
let garbageSig = (try? sigTestKey.signature(for: signedGarbage))?.base64EncodedString() ?? ""
expect(UpdateSignature.verify(manifestBytes: signedGarbage, signatureBase64: garbageSig, publicKeyBase64: sigTestPub)
       && (try? UpdateManifest.decode(signedGarbage)) == nil,
       "signed garbage verifies but does not decode (must fall back, not go quiet)")

// MARK: - UpdateInstaller refusal conditions

expectEqual(UpdateInstaller.refusalReason(
        bundlePath: "/private/var/folders/x/AppTranslocation/y/d/SonosBar.app",
        parentWritable: true, osVersion: "27.0", minimumSystemVersion: "26.0"),
    .translocated, "translocated bundle refused")
expectEqual(UpdateInstaller.refusalReason(
        bundlePath: "/Applications/SonosBar.app",
        parentWritable: false, osVersion: "27.0", minimumSystemVersion: "26.0"),
    .notWritable, "unwritable parent refused")
expectEqual(UpdateInstaller.refusalReason(
        bundlePath: "/Applications/SonosBar.app",
        parentWritable: true, osVersion: "26.0", minimumSystemVersion: "27.0"),
    .osTooOld, "manifest demanding newer OS refused")
expect(UpdateInstaller.refusalReason(
        bundlePath: "/Applications/SonosBar.app",
        parentWritable: true, osVersion: "27.0", minimumSystemVersion: "26.0") == nil,
    "normal install location accepted")

// MARK: - UpdateInstaller payload gate

let gateManifest = try! UpdateManifest.decode(Data(goodManifestJSON.utf8))
expectEqual(UpdateInstaller.validatePayload(
        infoPlist: nil, manifest: gateManifest, expectedBundleID: "app.sonosbar.SonosBar"),
    .unreadablePlist, "missing payload plist rejected")
expectEqual(UpdateInstaller.validatePayload(
        infoPlist: ["CFBundleIdentifier": "com.attacker.payload",
                    "CFBundleShortVersionString": "0.6.0"],
        manifest: gateManifest, expectedBundleID: "app.sonosbar.SonosBar"),
    .identifierMismatch("com.attacker.payload"), "foreign bundle id rejected")
expectEqual(UpdateInstaller.validatePayload(
        infoPlist: ["CFBundleIdentifier": "app.sonosbar.SonosBar",
                    "CFBundleShortVersionString": "0.5.0"],
        manifest: gateManifest, expectedBundleID: "app.sonosbar.SonosBar"),
    .versionMismatch("0.5.0"), "payload version != manifest rejected")
expect(UpdateInstaller.validatePayload(
        infoPlist: ["CFBundleIdentifier": "app.sonosbar.SonosBar",
                    "CFBundleShortVersionString": "0.6.0"],
        manifest: gateManifest, expectedBundleID: "app.sonosbar.SonosBar") == nil,
    "matching payload accepted")

// MARK: - EQ clamp

expectEqual(EQSettings.clampEQ(15), 10, "EQ clamps above +10")
expectEqual(EQSettings.clampEQ(-15), -10, "EQ clamps below -10")
expectEqual(EQSettings.clampEQ(3), 3, "EQ passes an in-range value")

// MARK: - Security guards

// EventServer.slicedBody: trims to declared Content-Length, passes through otherwise.
expectEqual(EventServer.slicedBody(Data("0123456789".utf8), contentLength: 4),
            Data("0123".utf8), "slicedBody trims to Content-Length")
expectEqual(EventServer.slicedBody(Data("0123".utf8), contentLength: nil),
            Data("0123".utf8), "slicedBody passes through when no Content-Length")
expectEqual(EventServer.slicedBody(Data("0123".utf8), contentLength: 99),
            Data("0123".utf8), "slicedBody keeps full body when length exceeds it")
expectEqual(EventServer.slicedBody(Data("0123".utf8), contentLength: -1),
            Data("0123".utf8), "slicedBody ignores a negative Content-Length")

// synthesizeDIDL escapes attacker-influenced title/URI before it becomes DIDL.
do {
    let didl = SOAPTransport.synthesizeDIDL(title: "A & B <x>", uri: "u?q=1&r=2")
    expect(didl.contains("A &amp; B &lt;x&gt;"), "synthesizeDIDL escapes the title")
    expect(didl.contains("u?q=1&amp;r=2"), "synthesizeDIDL escapes the uri")
    expect(!didl.contains("<x>"), "synthesizeDIDL leaves no raw injected tag")
}

// UpdateChecker.sanitizedReleaseURL: https + github.com only.
expect(UpdateChecker.sanitizedReleaseURL("https://github.com/mlaplante/sonosbar") != nil,
       "sanitizedReleaseURL accepts https github.com")
expect(UpdateChecker.sanitizedReleaseURL("file:///etc/passwd") == nil,
       "sanitizedReleaseURL rejects file:")
expect(UpdateChecker.sanitizedReleaseURL("https://evil.example/x") == nil,
       "sanitizedReleaseURL rejects a foreign host")
expect(UpdateChecker.sanitizedReleaseURL("http://github.com/x") == nil,
       "sanitizedReleaseURL rejects plain http")
expect(UpdateChecker.sanitizedReleaseURL(nil) == nil,
       "sanitizedReleaseURL rejects nil")

// SSDPDiscovery.isPrivateOrLinkLocalIPv4: RFC1918 + link-local + loopback only.
for ok in ["10.0.6.63", "192.168.1.1", "172.16.0.1", "172.31.255.255", "169.254.1.2", "127.0.0.1"] {
    expect(SSDPDiscovery.isPrivateOrLinkLocalIPv4(ok), "private range accepts \(ok)")
}
for bad in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "1.2.3.4", "example.com", "", "10.0.0", "10.0.0.256", "10.0.0.01"] {
    expect(!SSDPDiscovery.isPrivateOrLinkLocalIPv4(bad), "private range rejects \(bad)")
}

// MARK: - Summary

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
