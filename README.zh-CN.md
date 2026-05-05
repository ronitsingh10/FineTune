<img src="assets/icon.png" width="170" height="170" alt="FineTune 应用图标" align="left"/>

<h3>FineTune</h3>

为每一个 App 单独控制音量、把过轻的声音最高放大 4 倍、把音频路由到不同的扬声器，再用 EQ 和耳机曲线把声音调到自己喜欢的样子。常驻菜单栏，免费且开源。

<a href="https://github.com/ronitsingh10/FineTune/releases/latest/download/FineTune.dmg"><img src="assets/download-badge.svg" alt="下载 macOS 版本" height="48"/></a>

<br clear="all"/>

<p align="center">
  <a href="https://github.com/ronitsingh10/FineTune/releases/latest"><img src="https://img.shields.io/github/v/release/ronitsingh10/FineTune?style=for-the-badge&labelColor=1c1c1e&color=0A84FF&logo=github&logoColor=white" alt="最新版本"></a>
  <a href="https://github.com/ronitsingh10/FineTune/releases"><img src="https://img.shields.io/github/downloads/ronitsingh10/FineTune/total?style=for-the-badge&labelColor=1c1c1e&color=3a3a3c" alt="下载量"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-3a3a3c?style=for-the-badge&labelColor=1c1c1e" alt="许可证：GPL v3"></a>
  <a href="https://ko-fi.com/ronitsingh10"><img src="https://img.shields.io/badge/Tip_on_Ko--fi-FF5E5B?style=for-the-badge&labelColor=1c1c1e&logo=ko-fi&logoColor=white" alt="在 Ko-fi 打赏"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-15%2B-3a3a3c?style=for-the-badge&labelColor=1c1c1e&logo=apple&logoColor=white" alt="macOS 15+"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<p align="center">
  <img src="assets/screenshot-main.png" alt="FineTune 显示按 App 控制音量、EQ 与多设备输出" width="750">
</p>

## 安装

**Homebrew**（推荐）

```bash
brew install --cask finetune
```

**手动安装** —— [下载最新版本](https://github.com/ronitsingh10/FineTune/releases/latest)

## 快速上手

1. 安装 FineTune，从「应用程序」文件夹中启动
2. 在系统弹出权限请求时，授予 **屏幕与系统音频录制** 权限
3. 点击菜单栏中的 FineTune 图标，正在播放音频的 App 会自动出现

就是这样。直接拖动滑块、切换音频路由，或在菜单栏里玩一下 EQ 即可。

> **小贴士：** 想让 FineTune 在某台设备接入时自动切换过去？打开编辑模式（铅笔图标），把它拖到内置扬声器上方即可。这是一次性设置，你的偏好顺序会被永久保存。

## 功能

### 🎚 音量控制
- **按 App 控制音量** —— 为每个应用提供独立的音量滑块和静音
- **按 App 增益** —— 提供 2x / 3x / 4x 三档增益预设
- **置顶 App** —— 即使应用没有在播放声音，也让它一直显示在菜单栏中，方便提前配置音量、EQ 和路由
- **忽略 App** —— 让 FineTune 完全脱离指定的应用，撤掉对应的音频接入点，让该应用回到 macOS 默认的音频通路

### 🔀 音频路由
- **多设备输出** —— 同时将音频送往多台设备
- **音频路由** —— 把不同 App 分发到不同输出，或随系统默认输出走
- **设备优先级** —— 当新设备接入时，自定义 FineTune 切换的目标；当设备断开时，自动回退
- **自动恢复** —— 设备重新接入后，相关 App 会自动回到这台设备，并保留原本的音量、路由与 EQ 设置

### 🎛 EQ 与校正
- **10 段均衡器** —— 内置 5 大类、共 20 个预设
- **自定义 EQ 预设** —— 可按 App 保存、重命名和管理你自己的 EQ 配置
- **AutoEQ 耳机校正** —— 在数千条耳机曲线中搜索，或直接导入自己的 ParametricEQ.txt 文件，为每台设备进行频响校正
- **响度补偿** —— 在低音量下，依据 ISO 226:2023 等响度曲线自动补偿低频和高频，并实时管理整体电平，让感知响度保持一致

### 🖥 设备与系统
- **输入设备控制** —— 监控并调节麦克风电平
- **提示音音量** —— 在设置中控制 macOS 通知与提示音的音量
- **智能音量后端** —— FineTune 会按设备自动选择硬件、DDC 或软件音量。如果某台 USB DAC 或 HDMI 输出的硬件滑块根本不起作用，可以在设备详情里强制使用软件音量，FineTune 会记住这台设备的选择
- **设备详情** —— 点击任一设备旁的信息按钮，可以看到采样率（含选择器）、连接方式、UID 复制、独占模式提示，以及软件音量覆盖开关
- **隐藏设备** —— 在编辑模式下用「眼睛」按钮把不想出现在列表里的输出或输入设备隐藏起来，逻辑与隐藏 App 一致
- **蓝牙设备管理** —— 直接从菜单栏连接已配对的设备
- **显示器扬声器控制** —— 通过 DDC 调节外接显示器的音量
- **媒体按键与音量提示** —— 可选地接管 F10–F12 来控制默认输出设备，并在屏幕上显示 Tahoe 风格或经典风格的音量提示。所有写入都会走 FineTune 的音量管线，因此即使在 macOS 自身因为硬件滑块不可用而把媒体键灰掉的 USB 接口或 HDMI 输出上，按键依然有效
- **动态菜单栏图标** —— 在「设置」中可选择四种风格（Default、Speaker、Waveform、Equalizer）。其中 **Speaker** 风格会随音量实时切换图标（零 / 低 / 中 / 高），静音时显示带斜线的扬声器；切换设备时，所有风格都会短暂闪现新输出对应的 SF Symbol。切换风格立即生效，无需重启
- **菜单栏应用** —— 轻量、随时可用
- **URL Scheme** —— 通过脚本自动化控制音量、静音、设备路由等

## 截图

<p align="center">
  <img src="assets/screenshot-main.png" alt="FineTune 显示按 App 控制音量、EQ 与多设备输出" width="400">
  <img src="assets/screenshot-edit-mode.png" alt="FineTune 编辑模式中显示设备优先级、蓝牙配对以及 App 钉选/忽略控制" width="400">
</p>
<p align="center">
  <img src="assets/screenshot-autoeq.png" alt="FineTune AutoEQ 耳机校正选择器，支持搜索和收藏" width="400">
  <img src="assets/screenshot-settings.png" alt="FineTune 设置面板，含媒体按键与音量提示一栏" width="400">
</p>
<p align="center">
  <img src="assets/screenshot-device-inspector.png" alt="FineTune 设备详情显示采样率、格式、UID 与软件音量覆盖开关，下方为隐藏设备" width="400">
</p>

## 文档

- **[AutoEQ 与耳机校正](guide/autoeq.md)** —— 应用来自 [AutoEQ](https://github.com/jaakkopasanen/AutoEq) 项目的频响校正、导入 [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) 配置，或浏览 [autoeq.app](https://www.autoeq.app/)
- **[URL Scheme](guide/url-schemes.md)** —— 通过终端、[快捷指令](https://support.apple.com/guide/shortcuts-mac)、[Raycast](https://raycast.com) 或脚本自动化 FineTune
- **[排查指引](guide/troubleshooting.md)** —— 权限问题、应用未出现、声音异常等

## 参与贡献

- **给本仓库点 Star** —— 帮助更多人发现 FineTune
- **报告 Bug** —— [新建 issue](https://github.com/ronitsingh10/FineTune/issues)
- **贡献代码** —— 见 [CONTRIBUTING.md](CONTRIBUTING.md)

### 从源码构建

```bash
git clone https://github.com/ronitsingh10/FineTune.git
cd FineTune
open FineTune.xcodeproj
```

## 系统要求

- macOS 15.0 (Sequoia) 或更高版本
- 音频采集权限（首次启动时弹出请求）

## 支持作者

FineTune 永远免费且开源。如果它让你的一天稍微轻松了一点，可以请作者喝杯咖啡 —— 但完全不必勉强 🙏

[![请我喝咖啡](https://img.shields.io/badge/Buy_me_a_coffee-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/ronitsingh10)


## 许可证

[GPL v3](LICENSE)
