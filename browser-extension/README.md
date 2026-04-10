# UseTrack URL Tracker — Chrome Extension

追踪浏览器 URL 访问记录，通过 Native Messaging 发送给 UseTrack 采集器。

## 安装（开发者模式）

1. 打开 Chrome，访问 `chrome://extensions/`
2. 右上角开启 **开发者模式**
3. 点击 **加载已解压的扩展程序**
4. 选择 `browser-extension/` 目录

## Native Messaging Host 配置

扩展通过 Native Messaging 与 UseTrack 采集器通信。需要注册 Native Messaging host：

1. 创建 host manifest 文件 `com.usetrack.browser.json`：

```json
{
  "name": "com.usetrack.browser",
  "description": "UseTrack Browser URL Collector",
  "path": "/path/to/usetrack-browser-host",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://<extension-id>/"
  ]
}
```

2. 将 manifest 放置到对应目录：
   - **macOS**: `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`
   - **Linux**: `~/.config/google-chrome/NativeMessagingHosts/`

3. 将 `<extension-id>` 替换为扩展安装后显示的实际 ID

> **注意**: 如果 Native Messaging host 未配置，扩展会自动 fallback 到 `chrome.storage.local` 暂存数据，等待后续拉取。

## 支持的浏览器

| 浏览器 | 支持状态 | 备注 |
|--------|---------|------|
| Google Chrome | ✅ | 主要支持 |
| Arc | ✅ | 基于 Chromium |
| Microsoft Edge | ✅ | 基于 Chromium |
| Brave | ✅ | 基于 Chromium |

## 数据格式

每次 URL 访问发送如下 JSON：

```json
{
  "type": "url_visit",
  "url": "https://example.com/page",
  "title": "Page Title",
  "timestamp": "2026-04-10T12:00:00.000Z",
  "domain": "example.com"
}
```
