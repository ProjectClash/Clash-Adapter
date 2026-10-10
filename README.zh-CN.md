<p align="center">
  <img src="https://clash.md/brand/clash-app-icon.png" width="128" height="128" alt="Clash">
</p>

# Clash Adapter

[English](README.md) · 简体中文

[![官方网站](https://img.shields.io/badge/%E5%AE%98%E7%BD%91-%E8%AE%BF%E9%97%AE-2563EB)](https://clash.md/)
[![App Store 下载](https://img.shields.io/badge/App_Store-%E4%B8%8B%E8%BD%BD-black?logo=apple&logoColor=white)](https://apps.apple.com/app/id6794257189)
[![Telegram 频道](https://img.shields.io/badge/Telegram-%E9%A2%91%E9%81%93-26A5E4?logo=telegram&logoColor=white)](https://t.me/clashbyclash)
[![Telegram 交流群](https://img.shields.io/badge/Telegram-%E4%BA%A4%E6%B5%81%E7%BE%A4-26A5E4?logo=telegram&logoColor=white)](https://t.me/+t__WNRvjUbk3M2Nl)

用于连接 Apple Packet Tunnel 扩展与代理内核的 Swift 组件。本仓库包含 Clash 客户端使用的数据包桥接与扩展生命周期代码。

完整应用见 [Clash-Client](https://github.com/ProjectClash/Clash-Client)，代理内核与 SDK 构建工具见 [Clash](https://github.com/ProjectClash/Clash)。

## 组件

| 源文件 | 职责 |
| --- | --- |
| [`PacketFlowBridge.swift`](Sources/ClashAdapter/PacketFlowBridge.swift) | 在 `NEPacketTunnelFlow` 与文件描述符之间传递数据包，处理帧格式、有界队列和流量统计 |
| [`ProviderLifecycle.swift`](Sources/ClashAdapter/ProviderLifecycle.swift) | 协调扩展状态、会话所有权、重载、清理与物理网络路径监测 |

这些组件使用 Apple 系统框架，不包含代理引擎、应用界面或完整的 `NEPacketTunnelProvider` 实现。

## 版本与依赖

Swift 包和构建目标均名为 `ClashAdapter`。[`Package.swift`](Package.swift) 未声明外部包依赖；组件使用 Apple 系统框架，不会自行下载或链接内核 SDK。内核接入由使用这些组件的应用负责。

Adapter 目前按源码提交发布，尚无发行标签，不沿用内核的 `1.19.32` 版本号。客户端的 [`Dependencies.lock.json`](https://github.com/ProjectClash/Clash-Client/blob/main/Dependencies.lock.json) 同时记录已验证的 Kernel 和 Adapter 提交。

## 环境要求

- macOS、Xcode 及目标平台 SDK。
- 包清单声明 Swift 工具版本为 5.9；当前验证使用 Xcode 27.0。
- 部署目标为 iOS 15+、macOS 13+ 或 tvOS 17+。
- 由应用自行配置所需能力与签名的 Packet Tunnel 扩展。

## 集成源码

单独在 macOS 上构建此包：

```sh
git clone https://github.com/ProjectClash/Clash-Adapter.git
cd Clash-Adapter
swift build -c release
```

这只检查包在当前 Mac 上的编译，不会生成 Packet Tunnel 应用，也不代表已验证真机运行。需要可复现的集成时，请在构建前切到应用所固定的 Adapter 提交。

当前类型使用 Swift 的 `internal` 访问级别，需要与调用方一起编译进同一个构建目标。仅从另一个模块导入该包，无法将这些类型作为公开 API 使用。

1. 检出本仓库的固定提交。
2. 将 `Sources/ClashAdapter` 下的文件加入 Packet Tunnel 扩展构建目标，并保留随附许可证。
3. 在自己的扩展中接入内核，协调启动、网络设置、数据包处理和停止流程。

应用源码及依赖准备流程已在 [Clash-Client](https://github.com/ProjectClash/Clash-Client) 公开；其依赖准备脚本会把固定提交的 Adapter 源码复制到使用它们的构建目标。

`PacketFlowBridge.start()` 返回套接字对中面向内核的文件描述符，数据包带四字节地址族前缀；它不是 Apple 私有的 utun 描述符。隧道会话期间应持有桥接对象，并在清理时调用 `stop()`。描述符所有权与错误处理以源码为准。

`ApplePhysicalPathMonitor` 提供当前物理接口与接口清单，可通过可选的 `logHandler` 接收路径诊断。使用 Clash SDK 的接口迭代器和应用日志接线位于 Client 仓库。

## 状态与反馈

请固定具体提交，并在自己的应用中验证生命周期和数据包收发。仓库的包声明用于描述构建结构，不代表已经提供稳定的外部 Swift API。

组件问题请提交到本仓库的 [Issues](https://github.com/ProjectClash/Clash-Adapter/issues)，附上提交、目标平台和最小复现。应用问题请提交到 [Clash-Client](https://github.com/ProjectClash/Clash-Client/issues)，内核问题请提交到 [Clash](https://github.com/ProjectClash/Clash/issues)。公开反馈中请移除凭据和订阅链接。安全问题请遵循 [SECURITY.md](SECURITY.md)。

## 许可证

[GPL-3.0](LICENSE)。署名信息见源码与许可证文件。
