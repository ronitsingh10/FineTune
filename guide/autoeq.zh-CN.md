# AutoEQ 与耳机校正

[English](autoeq.md) · **简体中文**

> 本翻译由社区维护，更新可能晚于英文版。最新内容请以 [English version](autoeq.md) 为准。
> *This translation is community-maintained and may lag the English version. See the [English version](autoeq.md) for the most current information.*

FineTune 可以使用来自 [AutoEQ](https://github.com/jaakkopasanen/AutoEq) 项目的耳机专属频响校正配置。它会针对你耳机本身的频率曲线做补偿，让声音更平直、更准确。

## 工作原理

每副耳机对声音的染色都不一样：有的低频偏多，有的高频刺耳。AutoEQ 测量出这些偏离，并生成对应的修正 EQ 滤波器。FineTune 会按设备分别应用这些滤波器，所以每副耳机都拥有自己独立的校正配置。

校正会叠加在 FineTune 的 10 段 EQ 之上，因此应用一份配置之后，你仍然可以按个人口味继续微调。

## 浏览内置配置

1. 点击 FineTune 中任一耳机设备旁的 **魔棒图标**
2. 按型号搜索你的耳机
3. 选中一个配置，立即生效

配置会按需从 AutoEQ 数据库拉取，并在本地缓存以便离线使用。数据库覆盖了主流厂商上千款耳机（Sony、Sennheiser、Apple、Bose、Audio-Technica、Beyerdynamic 等）。

> **小贴士：** 如果你的具体型号没出现在列表里，可以试着搜索同一产品线 —— 相近型号的频响特性往往相近。

## 导入自定义配置

如果你有自己的测量结果，或者想用其他来源的配置：

1. 点击 AutoEQ 面板底部的 **"Import ParametricEQ.txt..."**
2. 选择你的 `.txt` 文件
3. 配置会被导入并应用到当前选中的设备
4. 使用选择器中的 **Correction** 开关，可以在不删除配置的前提下做 A/B 对比

FineTune 接受 [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) 的 ParametricEQ.txt 文件：

```
Preamp: -6.2 dB
Filter 1: ON PK Fc 100 Hz Gain -2.3 dB Q 1.41
Filter 2: ON LSC Fc 105 Hz Gain 7.0 dB Q 0.71
Filter 3: ON HSC Fc 8000 Hz Gain 2.1 dB Q 0.71
```

### 支持的滤波器类型

| 代码 | 类型 | 说明 |
|------|------|-------------|
| `PK` / `PEQ` | Peaking | 在某段窄频带上提升或衰减 |
| `LS` / `LSC` | Low shelf | 提升或衰减某频率以下的所有内容 |
| `HS` / `HSC` | High shelf | 提升或衰减某频率以上的所有内容 |

每份配置最多 10 个滤波器。`Preamp` 行设定一个全局增益偏移，用于避免削波。

## 在哪里获取配置

- **内置搜索** —— 最方便的方式。FineTune 直接内置了上千款耳机
- **[autoeq.app](https://www.autoeq.app/)** —— 网页版工具，选项更丰富。把 equalizer app 选成 **EqualizerAPO ParametricEq**，下载文件后导入 FineTune 即可
- **[AutoEQ GitHub](https://github.com/jaakkopasanen/AutoEq)** —— 完整的测量数据与生成配置仓库
- **自行测量** —— 如果你自己测量了耳机（例如用 MiniDSP EARS 之类的设备），可以按上面的格式在任意文本编辑器里手写一个 ParametricEQ.txt 文件

## 管理配置

- 每台设备都会独立记住自己绑定的配置
- 要临时旁路一个配置，点击魔棒图标并把 **Correction** 关掉
- 要彻底移除一个配置，点击魔棒图标并选择 **No correction**
- 用星标图标把常用的配置加入收藏，方便快速访问 —— 收藏过的配置会出现在搜索结果顶部，搜索框为空时也会一并显示
