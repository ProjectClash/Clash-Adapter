# Clash Adapter

English · [简体中文](README.zh-CN.md)

[![Website](https://img.shields.io/badge/Website-Official-2563EB)](https://clash.md/)
[![App Store Download](https://img.shields.io/badge/App_Store-Download-black?logo=apple&logoColor=white)](https://apps.apple.com/app/id6794257189)
[![Telegram Channel](https://img.shields.io/badge/Telegram-Channel-26A5E4?logo=telegram&logoColor=white)](https://t.me/clashbyclash)
[![Telegram Group](https://img.shields.io/badge/Telegram-Group-26A5E4?logo=telegram&logoColor=white)](https://t.me/+t__WNRvjUbk3M2Nl)

Swift components for connecting an Apple Packet Tunnel provider to a proxy kernel. This repository contains the packet-flow bridge and provider lifecycle code used by the Clash client.

For the complete application, see [Clash-Client](https://github.com/ProjectClash/Clash-Client). The proxy kernel and SDK build tools are in [Clash](https://github.com/ProjectClash/Clash).

## Components

| Source | Responsibility |
| --- | --- |
| [`PacketFlowBridge.swift`](Sources/ClashAdapter/PacketFlowBridge.swift) | Transfers packets between `NEPacketTunnelFlow` and a file descriptor, with framing, bounded queues and flow statistics |
| [`ProviderLifecycle.swift`](Sources/ClashAdapter/ProviderLifecycle.swift) | Coordinates provider state, session ownership, reloads, teardown and physical network path monitoring |

These components use Apple system frameworks. They do not include a proxy engine, an application interface or a complete `NEPacketTunnelProvider` implementation.

## Requirements

- macOS with Xcode and the SDK for your target platform.
- Swift 5.9 or later.
- Deployment targets: iOS 15+, macOS 13+ or tvOS 17+.
- A Packet Tunnel extension with its required capabilities and signing configured by your application.

## Integrate the sources

The current types have Swift `internal` access. Compile the source files in your consuming target; importing the package from another module does not expose these types as a public API.

1. Check out a specific revision of this repository.
2. Add the files under `Sources/ClashAdapter` to your Packet Tunnel extension target, keeping the accompanying license.
3. Supply your kernel connection and coordinate startup, network settings, packet handling and shutdown in your provider.

The application source and its dependency setup are being prepared in [Clash-Client](https://github.com/ProjectClash/Clash-Client).

`PacketFlowBridge.start()` returns the core-facing descriptor of a socket pair. The descriptor carries packets with a four-byte address-family prefix; it is not Apple's private utun descriptor. Keep the bridge alive for the tunnel session and call `stop()` during teardown. See the source for descriptor ownership and error handling.

`ApplePhysicalPathMonitor` exposes the current physical interface and interface inventory. Supply its optional `logHandler` to receive path diagnostics. The Clash SDK interface iterator and application logging integration live in the Client repository.

## Status and feedback

This is pre-release integration code. Pin a revision and validate the lifecycle and packet flow in your own application. The repository's package declaration describes its build structure; it does not promise a stable external Swift API.

Report component problems in [Issues](https://github.com/ProjectClash/Clash-Adapter/issues), including the revision, target platform and a minimal reproduction. App issues belong in [Clash-Client](https://github.com/ProjectClash/Clash-Client/issues); kernel issues belong in [Clash](https://github.com/ProjectClash/Clash/issues). Remove credentials and subscription links from public reports. Follow [SECURITY.md](SECURITY.md) for security reports.

## License

[GPL-3.0](LICENSE). See the source and license file for attribution.
