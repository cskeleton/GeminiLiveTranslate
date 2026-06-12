# GeminiLiveTranslate - 实时直播翻译

一个轻量级的实时翻译字幕工具，使用 Google 的 Gemini 3.5 Live Translate API。为视频播放器提供即插即用的实时翻译体验。

**English**: [README.md](README.md)

## 功能特性

- **实时音频翻译**：使用 Gemini Live Translate API 实时翻译系统音频
- **IINA 播放器集成**：与 IINA 播放器自动同步音频延迟
- **智能延迟追踪**：基于语句的延迟采样，自适应 EMA 平滑
- **自适应缓冲**：采用 FIFO 抖动缓冲，不丢弃突发音频，暂停时平稳播放
- **字幕导出**：支持将翻译结果保存为字幕文件

## 系统需求

- macOS 14 或更高版本
- 互联网连接
- [Google Gemini API 密钥](https://aistudio.google.com/apikey)（Gemini 3.5 Live Translate 提供免费额度）
- （可选）IINA 播放器用于字幕显示和延迟同步

## 安装

### 从 Release 安装

1. 从 [Releases 页面](https://github.com/cskeleton/GeminiLiveTranslate/releases) 下载最新版本
2. 解压档案：
   ```bash
   tar -xzf GeminiLiveTranslate-macos.tar.gz
   ```
3. 复制可执行文件：
   ```bash
   cp dist/GeminiLiveTranslate ~/.local/bin/
   ```
4. （可选）安装 IINA 插件：
   ```bash
   mkdir -p ~/.config/iina/plugins/
   cp -r dist/GeminiLiveSync.iinaplugin ~/.config/iina/plugins/
   ```

### 从源码编译

1. 克隆仓库：
   ```bash
   git clone https://github.com/cskeleton/GeminiLiveTranslate.git
   cd GeminiLiveTranslate
   ```
2. 使用 Swift 编译：
   ```bash
   swift build -c release
   ```
3. 运行：
   ```bash
   .build/release/GeminiLiveTranslate
   ```

## 配置

1. 启动应用程序
2. 在设置中输入你的 Gemini API 密钥（在 [Google AI Studio](https://aistudio.google.com/apikey) 免费获取）
3. 选择翻译的目标语言
4. （可选）如果使用 IINA 播放器，启用 IINA 同步功能
5. 点击"开始翻译"按钮

## 截图

### 应用界面
![应用界面](screenshots/app.png)

### 字幕叠加
![字幕叠加](screenshots/subtitles.png)

## 架构设计

### 核心组件

- **AudioPlayer**：FIFO 抖动缓冲，自适应 AudioQueue 管理
- **LatencyTracker**：基于语句的延迟采样，锚定到 Gemini 的 ASR 流
- **GeminiWebSocket**：Gemini Live API 的双向 WebSocket 客户端
- **SystemAudioCapture**：ScreenCaptureKit 音频提取和格式转换
- **WebSocketServer**：IINA 插件的本地 HTTP/WebSocket 服务器

### 延迟测量原理

语音起点锚定到 Gemini 的 `inputTranscription` 事件（服务器端 ASR 能识别语音）而非本地能量检测。当第一个翻译音频块到达时，采样计算为：

```
延迟 = (当前时刻 - 语句开始) + 播放队列长度
```

采用自适应 EMA 平滑（>1s 变化时 α=0.3，较小变化时 α=0.1），每个语句只发布一次，消除启动飙升和逐块更新产生的噪声。

## IINA 插件

`GeminiLiveSync.iinaplugin` 自动执行以下操作：
- 监测视频暂停/恢复并通知翻译器
- 检测进度条拖动事件并清空过期音频
- 从翻译器轮询延迟值，应用 `audio-delay` 同步视频
- 使用滞后控制（≥0.4s 变化阈值，≥5s 调整间隔）减少卡顿

## 已知限制

- 仅支持系统音频（不支持应用内特定音频）
- 延迟估计在前几个语句后逐步稳定
- 如果对白中没有 2 秒以上的静音间隙，语句级采样可能延迟
- IINA 插件安装后需要手动加载

## 开发

### 编译

```bash
swift build -c release
```

### 代码结构

```
Sources/GeminiLiveTranslate/
├── AudioPlayer.swift         # 音频播放和缓冲
├── LatencyTracker.swift       # 延迟测量和 EMA
├── GeminiWebSocket.swift      # Gemini API 客户端
├── SystemAudioCapture.swift   # 系统音频捕获
├── TranslationEngine.swift    # 主要编排逻辑
├── WebSocketServer.swift      # IINA 插件 HTTP/WebSocket 服务器
├── AppState.swift             # SwiftUI 状态管理
├── SettingsView.swift         # 设置界面
├── SubtitleOverlayWindow.swift # 字幕显示窗口
└── main.swift                 # 入口点
```

## 许可证

MIT

## 致谢

- Google Gemini Live Translate API
- IINA 媒体播放器
- ScreenCaptureKit 音频捕获库
