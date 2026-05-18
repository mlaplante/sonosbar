//
//  SOAPServices.swift
//  SonosBar
//
//  Static definitions for the four UPnP services we touch on a Sonos player.
//  Centralised so service URNs and control paths don't drift across the
//  command files (they did exactly this in an earlier draft and produced
//  a frustrating "ERROR 401 Invalid Action" debugging session).
//
//  These constants come from each Sonos device's device_description.xml,
//  which we fetched in chunk 2. They've been stable since the S1 era.
//

import Foundation

enum SOAPService {

    case avTransport
    case renderingControl
    case zoneGroupTopology
    case contentDirectory
    case musicServices

    /// Service type URN, used in both the SOAPACTION header and the
    /// xmlns:u attribute on the body element.
    var serviceType: String {
        switch self {
        case .avTransport:       return "urn:schemas-upnp-org:service:AVTransport:1"
        case .renderingControl:  return "urn:schemas-upnp-org:service:RenderingControl:1"
        case .zoneGroupTopology: return "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        case .contentDirectory:  return "urn:schemas-upnp-org:service:ContentDirectory:1"
        case .musicServices:     return "urn:schemas-upnp-org:service:MusicServices:1"
        }
    }

    /// HTTP path on port 1400 for the control endpoint.
    var controlPath: String {
        switch self {
        case .avTransport:       return "/MediaRenderer/AVTransport/Control"
        case .renderingControl:  return "/MediaRenderer/RenderingControl/Control"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Control"
        case .contentDirectory:  return "/MediaServer/ContentDirectory/Control"
        case .musicServices:     return "/MusicServices/Control"
        }
    }

    /// HTTP path on port 1400 for the event subscription endpoint.
    /// (Used in chunk 5 when GENA subscriptions go live.)
    var eventPath: String {
        switch self {
        case .avTransport:       return "/MediaRenderer/AVTransport/Event"
        case .renderingControl:  return "/MediaRenderer/RenderingControl/Event"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Event"
        case .contentDirectory:  return "/MediaServer/ContentDirectory/Event"
        case .musicServices:     return "/MusicServices/Event"
        }
    }
}
