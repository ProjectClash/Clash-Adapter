<p align="center">
  <img src="https://clash.md/brand/clash-app-icon.png" width="128" height="128" alt="Clash">
</p>

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

## Versions and dependencies

The Swift package and target are named `ClashAdapter`. [`Package.swift`](Package.swift) declares no external package dependencies; the components use Apple system frameworks and do not download or link a Kernel SDK themselves. The consuming application supplies the kernel integration.

Adapter is published by source commit, with no release tag at present. It does not share the kernel's `1.19.33` version number. The Client's [`Dependencies.lock.json`](https://github.com/ProjectClash/Clash-Client/blob/main/Dependencies.lock.json) records the tested Kernel and Adapter revisions together.

## Requirements

- macOS with Xcode and the SDK for your target platform.
- Swift tools version 5.9, as declared by the package manifest. Current verification uses Xcode 27.0.
- Deployment targets: iOS 15+, macOS 13+ or tvOS 17+.
- A Packet Tunnel extension with its required capabilities and signing configured by your application.

## Integrate the sources

For a standalone macOS package build:

```sh
git clone https://github.com/ProjectClash/Clash-Adapter.git
cd Clash-Adapter
swift build -c release
```

This checks the package on the host Mac; it does not build a Packet Tunnel app or validate device operation. For a reproducible integration, select the Adapter revision pinned by your application before building.

The current types have Swift `internal` access. Compile the source files in your consuming target; importing the package from another module does not expose these types as a public API.

1. Check out a specific revision of this repository.
2. Add the files under `Sources/ClashAdapter` to your Packet Tunnel extension target, keeping the accompanying license.
3. Supply your kernel connection and coordinate startup, network settings, packet handling and shutdown in your provider.

The application source and dependency setup are available in [Clash-Client](https://github.com/ProjectClash/Clash-Client). Its bootstrap copies the pinned Adapter sources into the consuming targets.

`PacketFlowBridge.start()` returns the core-facing descriptor of a socket pair. The descriptor carries packets with a four-byte address-family prefix; it is not Apple's private utun descriptor. Keep the bridge alive for the tunnel session and call `stop()` during teardown. See the source for descriptor ownership and error handling. Supply the optional `logLine` callback to receive packet-flow fault diagnostics.

`ApplePhysicalPathMonitor` exposes the current physical interface and interface inventory. Supply its optional `logHandler` to receive path diagnostics. The Clash SDK interface iterator and application logging integration live in the Client repository.

## Status and feedback

Pin a revision and validate the lifecycle and packet flow in your own application. The repository's package declaration describes its build structure; it does not promise a stable external Swift API.

Report component problems in [Issues](https://github.com/ProjectClash/Clash-Adapter/issues), including the revision, target platform and a minimal reproduction. App issues belong in [Clash-Client](https://github.com/ProjectClash/Clash-Client/issues); kernel issues belong in [Clash](https://github.com/ProjectClash/Clash/issues). Remove credentials and subscription links from public reports. Follow [SECURITY.md](SECURITY.md) for security reports.

## License

[GPL-3.0](LICENSE). See the source and license file for attribution.
