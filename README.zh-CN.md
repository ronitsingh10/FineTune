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
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-15.4%2B-3a3a3c?style=for-the-badge&labelColor=1c1c1e&logo=apple&logoColor=white" alt="macOS 15.4+"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

> 本中文版由社区维护，并依据当前代码持续更新。内容更新可能会有延迟；若文档与实际行为不一致，请以已安装版本和[最新发布说明](https://github.com/ronitsingh10/FineTune/releases/latest)为准。
> This Chinese version is maintained by the community and continuously updated based on the current code. Content updates may be delayed; if the documentation is inconsistent with actual behavior, please refer to the installed version and the [latest release notes](https://github.com/ronitsingh10/FineTune/releases/latest).

<p align="center">
  <img src="assets/screenshot-main.png" alt="FineTune 弹窗：按 App 控制音量、多设备输出路由（含设备选择浮窗）、AutoEQ 耳机校正以及设备级音量滑块" width="700">
</p>
<p align="center">
  <img src="assets/screenshot-eq.png" alt="FineTune：Brave 浏览器一行展开，EQ 面板打开，已选中「Vocal Clarity」预设" width="700">
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
- **滚轮调节音量** —— 把鼠标悬停到弹窗、HUD 或 EQ 面板的任一滑块上，滚动滚轮即可调节
- **精确输入音量** —— 点击 App、输出设备或输入设备行右侧的百分比，可以直接输入目标数值，不必只靠拖动滑块

### ⌨️ 键盘
- **全局音量快捷键** —— 在 设置 → 快捷键 中，给 **App Volume Up**、**App Volume Down** 与 **App Mute** 自定义按键。这里的「App」指的是当前在发声的应用，所以当 YouTube 标签页在后台播放、终端在前台时，按下音量减只会调小 YouTube，不会动到终端。如果当前没有任何声音，快捷键会回退到最前台的应用
- **从任何地方唤起弹窗** —— 给 **Toggle FineTune Popup** 绑定一个快捷键，菜单栏弹窗就能随时开关，即便在全屏应用中也可以
- **可调节的步长** —— 在 设置 → 快捷键 → Volume Step 里选择 **Coarse / Normal / Fine / Extra-Fine**。这一项同时控制 F10–F12 媒体键、全局快捷键，以及弹窗里的方向键导航
- **长按连续调节、调高时自动取消静音** —— 长按 App Volume Up 或 Down 会像 macOS 的方向键一样持续触发；当处于静音状态按音量加，会一次性取消静音并设置到新音量
- **键盘操作弹窗** —— 弹窗打开后，**↑ / ↓** 在行间移动，**← / →** 调节当前焦点行的音量（按住 Shift = 2 倍步长），直接输入数字并按 **Return** 可精确设置音量，**M** 切换静音，**Return / Space** 触发，**Tab** 在「输出」与「输入」设备标签间切换，**Esc** 关闭。焦点行会自动滚动到中央

### 🔀 音频路由
- **多设备输出** —— 同时将音频送往多台设备
- **音频路由** —— 把不同 App 分发到不同输出，或随系统默认输出走
- **设备优先级** —— 当新设备接入时，自定义 FineTune 切换的目标；当设备断开时，自动回退。在编辑模式中既可拖动排序，也可点击序号直接输入新位置
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
- **自定义设备图标** —— 在编辑模式下点击设备图标，可从支持搜索的图标库中为输出或输入设备选择图标，也可随时恢复自动识别；自定义结果会同步显示在设备列表、路由选择器和菜单栏的设备图标样式中
- **蓝牙设备管理** —— 直接从菜单栏连接已配对的设备
- **显示器扬声器控制** —— 通过 DDC 调节外接显示器的音量
- **媒体按键与音量提示** —— 可选地接管 F10–F12 来控制默认输出设备，并在屏幕上显示 Tahoe 风格或经典风格的音量提示。调节音量时会遵循 macOS 的“更改音量时播放反馈”设置播放反馈音。所有写入都会走 FineTune 的音量管线，因此即使在 macOS 自身因为硬件滑块不可用而把媒体键灰掉的 USB 接口或 HDMI 输出上，按键依然有效
- **动态菜单栏图标** —— 在「设置」中可选择五种风格（Default、Speaker、Device、Waveform、Equalizer）。**Speaker** 会随音量实时切换图标（零 / 低 / 中 / 高），静音时显示带斜线的扬声器；**Device** 会持续显示当前输出设备的图标，并采用你为设备设置的自定义图标。其余风格在切换设备时会短暂闪现新输出对应的图标。切换风格立即生效，无需重启
- **菜单栏应用** —— 轻量、随时可用
- **URL Scheme** —— 通过脚本自动化控制音量、静音、设备路由等

### 🎨 外观
- **浅色或深色主题** —— 设置 → 通用 → 主题 跟随 macOS，或将 FineTune 锁定为浅色 / 深色。菜单栏弹窗、所有浮窗以及音量提示会立即切换
- **弹窗密度** —— 设置 → 通用 → Popup Size 选择 **Compact / Comfortable / Spacious**，并提供实时预览。Compact 在小屏幕上能容纳更多 App；Spacious 给触控板用户更大的点击区域

## 文档

- **[AutoEQ 与耳机校正](guide/autoeq.zh-CN.md)** —— 应用来自 [AutoEQ](https://github.com/jaakkopasanen/AutoEq) 项目的频响校正、导入 [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) 配置，或浏览 [autoeq.app](https://www.autoeq.app/)
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

- macOS 15.4 (Sequoia) 或更高版本
- 音频采集权限（首次启动时弹出请求）

## 支持作者

FineTune 永远免费且开源。如果它让你的一天稍微轻松了一点，可以请作者喝杯咖啡 —— 但完全不必勉强 🙏

[![请我喝咖啡](https://img.shields.io/badge/Buy_me_a_coffee-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/ronitsingh10)


## 许可证

[GPL v3](LICENSE)
