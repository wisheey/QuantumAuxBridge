# Quantum Aux Bridge for iPhone and iPad

Native Swift port of the QuantumAux Python bridge. One iPhone/iPad hosts the console connection and the existing musician web UI. Musicians use Safari on other devices on the same local network. No computer or internet connection is required during normal operation after the app is installed.

**Delivery status:** source project, not a signed IPA or App Store release. The JavaScript syntax, Swift grammar (without type checking), and project/resource structure were checked in the authoring environment. That environment has no Swift compiler, Xcode, iOS SDK, or physical Quantum 338. The Swift tests below are included but have **not been executed**, and the app has **not been compiled or tested on an iPhone/iPad or physical console**. Complete the Mac build and device acceptance steps before using it for a performance.

## What is included

- Native host dashboard for console IPv4 address, outgoing/incoming UDP ports, and browser TCP port.
- Local IPv4 addresses and copyable musician URLs.
- UDP OSC encoding/decoding, console discovery, input/aux names, mono/stereo aux modes, send level and pan feedback.
- Existing all-blue fader UI, silver handles with pointer capture, −50 to +10 dB sends, optional stereo pan, and no send on/off control.
- An HTTP server serving the UI and the same `/api/mixes`, `/api/claim`, `/api/state`, `/api/send`, `/api/release` endpoints.
- Atomic single-browser-session ownership per aux; automatic private token; no aux codes. Reservations expire after 30 seconds without authenticated activity. Leave mix releases immediately.
- All bridge state and requests execute on one serial queue. One musician cannot address another aux through the send API. Duplicate claims are serialized.
- No invented names or levels. Unknown/stale readback pauses writes. Reads below −50 dB remain accurate; dragging the fader sends values only within −50…+10 dB.
- Console session changes clear reservations. Mode changes clear reservations and feedback. Input-count changes advance the revision and invalidate feedback.
- Settings persist on the host. Leases, tokens and console readback do not persist across a restart.

## Install using a Mac

1. Install Xcode with an iOS SDK. The project targets **iOS/iPadOS 17 or later** and uses Swift 5 language mode, Foundation, SwiftUI, Network and Darwin. It has no third-party packages.
2. Open `QuantumAuxBridge.xcodeproj`.
3. Select the **QuantumAuxBridge** target → **Signing & Capabilities**. Choose your Apple development team and change `com.example.QuantumAuxBridge` to a unique bundle identifier for your account. Automatic signing is enabled.
4. Connect your iPhone/iPad to the Mac, trust the computer and enable Developer Mode if requested. Select that physical device as the run destination.
5. Build and Run. Accept the app’s Local Network permission prompt when starting the bridge.
6. Development installation is subject to the signing/provisioning limits of your Apple account. For distribution to other hosts, arrange appropriate signing/TestFlight separately. This ZIP is not directly installable in Safari.

The Mac is needed to build/install; it need not remain connected while hosting.

## Connect the console

1. Put the Quantum console’s control Ethernet interface and the host phone/tablet on the same reachable LAN. Use a Wi-Fi access point/router; disable wireless client isolation. Internet access is not needed.
2. Open the app. Enter the console’s actual control IPv4 address. Defaults are console receive UDP **8000**, phone receive UDP **9000**, and musician HTTP **8765**; match the UDP values to the console’s actual configuration.
3. Configure the console’s **DiGiCo Pad** external control device to send to the phone/tablet IPv4 address shown in the app and to the app’s receive UDP port. The console’s receive port must equal the app’s console receive UDP port. Avoid another controller competing for the same external-control configuration.
4. Tap **Start bridge**, allow Local Network access, and wait for live feedback and discovered input counts. No names or data are populated from a demo.
5. Musicians connect to the same LAN and open **`http://HOST-IP:8765`** (or the configured port) in Safari. Select a free aux. The host dashboard is the only configuration interface; `/setup` is intentionally unavailable over the network.
6. Keep the host powered with this app **visible**. It disables automatic screen lock while hosting. Manually locking the host or putting the app into the background stops listeners, clears queued queries and releases all reservations. Return to the app and tap Start bridge; musicians reselect their mixes. No background audio/VPN workaround is used.

Use another device for musician controls. This version does not include an embedded musician browser on the host and does not promise continued hosting while locked or backgrounded. Brief inactive states are left to iOS; stale feedback protection still applies. Reserve a stable DHCP address for the host if needed; restarting after a network change and updating the console’s destination may be necessary.

## Verify on a Mac and device

From this folder on a Mac with Swift installed:

```sh
swift test
xcodebuild -project QuantumAuxBridge.xcodeproj -scheme QuantumAuxBridge -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The Swift package tests the actual shared core and HTTP parser/router (not a rewritten model): OSC input, discovery, lease conflict/release/expiry, old-token rejection, value bounds, stale feedback, topology/session invalidation, read-only polling, strict JSON numeric types, fragmented HTTP, duplicate length rejection, cross-origin rejection and blocked setup/path traversal. Network.framework, Darwin transport, signing and SwiftUI require the Xcode build and device tests.

Device acceptance checklist:

1. Confirm the host asks for Local Network permission, starts the HTTP listener and shows a reachable LAN URL. Check denial/re-enable behavior in iOS Settings.
2. Check actual input count, input labels, aux labels, mono/stereo status and levels against the console. Opening a mix alone must never change audio controls.
3. Use two musician browsers and claim the same aux. Exactly one should succeed; another aux should remain independently available. Check Leave mix, 30-second expiry and stale-token rejection.
4. Move a test send to −50, 0 and +10 dB. Verify the correct input-to-aux send changes on the desk and feedback returns. Test pan only on a stereo aux. Test fader grabbing and dragging in iPad Safari.
5. Change names/levels on the console and confirm browser updates. Disconnect the console and verify writes pause; reconnect and confirm fresh feedback is required.
6. Change the console session/topology and confirm old browser requests cannot write with a stale revision. No on/off, master or unrelated channel commands are exposed.
7. Lock/background the host. Confirm browsers lose service and reservations are cleared. Foreground and explicitly restart; verify reconnection without replaying old writes.
8. Test all intended musicians simultaneously and observe feedback freshness. Polling is bounded to roughly 500 OSC queries/second; very large active configurations need load testing and may reach the 30-second stale timeout.

## Implementation notes

`BridgeCore.swift` holds protocol state and reservations. `HTTP.swift` is a bounded HTTP/1 parser and API router. `BridgeHost.swift` binds one IPv4 UDP socket and a Network.framework TCP listener. UDP replies are accepted only from the configured console IP; packets are decoded before mutating state. The same bound UDP socket sends queries and commands. Polling is paced at one query per approximately 2 ms. Requests have size, connection-count and completion-time limits. Console feedback is never updated speculatively after a send.

HTTP intentionally uses local cleartext, just like the Python bridge. Use a trusted isolated control network; do not forward these ports to the internet. Setup stays on the host but musician mix claims are open by design. Reservations govern this app only; they do not lock out physical desk controls or other console software. Source-IP filtering is not cryptographic authentication.

The port uses the same DiGiCo Pad address scheme as the Python build: `/Console/Channels/?`, `/Console/Aux_Outputs/modes/?`, `/Input_Channels/{id}/Channel_Input/name`, `/Aux_Outputs/{id}/Buss_Trim/name`, and `/Input_Channels/{input}/Aux_Send/{aux}/send_level` or `send_pan`. No `/sd` prefix and no normalized level conversion. Compatibility still requires physical-console verification.

## Apple references

- Network listener: https://developer.apple.com/documentation/network/nwlistener
- Local Network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Screen idle timer: https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled
- Background execution: https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time
