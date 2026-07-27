# iPhone 无线麦克风 / iPhone Wireless Mic

> 把你的 iPhone 变成 Mac 的无线麦克风，支持 Codex 语音输入、语音识别等场景。
> Turn your iPhone into a wireless microphone for your Mac.

## 概述 / Overview

Mac Mini 没有内置麦克风？没关系。这个项目让你用 **iPhone 的麦克风** 通过 Wi-Fi 实时传输音频到 Mac，并且通过 **BlackHole 虚拟音频驱动** 注册为系统级输入设备——所有 Mac 应用都可以直接使用。

### 音频链路 / Audio Pipeline

```
iPhone 麦克风 → Safari → HTTPS POST → Mac 服务器 → bh_player → BlackHole 2ch → 系统麦克风输入 → 任何 App
```

## 功能特性 / Features

- ✅ **实时传输** — 无缓冲，低延迟，音频实时流入 Mac
- ✅ **系统级麦克风** — 通过 BlackHole 注册为系统输入，任何 App 可用
- ✅ **屏幕常亮** — 使用 Wake Lock API，iPhone 息屏不中断
- ✅ **HTTPS 加密** — 自签名证书，局域网传输安全
- ✅ **即开即用** — iPhone 打开 Safari 即可，无需安装 App

## 安装 / Installation

### 前置依赖

```bash
pip3 install simpleaudio websockets
```

### 1. 安装 BlackHole 虚拟音频驱动

下载并安装 [BlackHole 2ch](https://existential.audio/blackhole/)（免费版），或通过 Homebrew：

```bash
brew install blackhole-2ch
```

### 2. 启动服务器

```bash
cd iphone-mic
python3 server.py
```

### 3. 连接 iPhone

1. 确保 iPhone 和 Mac 在**同一个 Wi-Fi**
2. iPhone Safari 打开 `https://[Mac的IP]:8080`
3. 绕过证书警告 → 点麦克风按钮 → 允许权限
4. 在系统设置 → 声音 → 输入中选择 **BlackHole 2ch**

## 使用 / Usage

### 常规使用

```
1. 运行 python3 server.py
2. iPhone Safari 打开服务器地址
3. 点击麦克风按钮开始传输
4. 在目标 App（Codex、Zoom 等）中选择 BlackHole 2ch 作为输入
```

### 开机自启

```bash
screen -dmS iphone-mic python3 server.py
```

## 项目结构 / Project Structure

```
iphone-mic/
├── server.py          # Mac HTTP/HTTPS 服务器
├── static/
│   └── index.html     # iPhone 端网页（音频采集 + Wake Lock）
├── bh_player.swift    # Swift 播放器（直接输出到 BlackHole）
├── cert.pem           # HTTPS 自签名证书
├── key.pem            # 证书私钥
└── cert.conf          # 证书配置（含 SAN）
```

## 技术栈 / Tech Stack

| 组件 | 技术 |
|------|------|
| Web 服务器 | Python `http.server` + SSL |
| 音频采集 | Web Audio API (ScriptProcessorNode) |
| 音频传输 | HTTP POST + 16-bit PCM |
| 音频播放 | `bh_player` (Swift + AudioUnit → BlackHole) |
| 虚拟驱动 | BlackHole 2ch |
| 屏幕常亮 | Screen Wake Lock API |

## 常见问题 / FAQ

**Q: 为什么没有声音？**
A: 检查 BlackHole 是否设为默认输出设备：系统设置 → 声音 → 输出 → 选择 BlackHole 2ch

**Q: iPhone 息屏后音频中断？**
A: 如果按电源键锁屏，iOS 会强制停止麦克风访问。页面使用 Wake Lock API 保持屏幕常亮

**Q: 延迟大吗？**
A: 局域网下延迟约 50-200ms，足以用于语音输入

## License

MIT
