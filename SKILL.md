---
name: dsh-screen-sense
description: 不截屏地读取当前屏幕状态（活动窗口、焦点控件、窗口列表、浏览器标签），输出有 token 上限的紧凑摘要；支持变更事件流。
---

# dsh-screen-sense

把「主人在电脑上做什么」压成 130 token 左右的结构化摘要，**不截屏、不上传**。

## 何时使用

- 需要知道用户在哪个应用、哪个窗口、焦点在什么控件上。
- 需要知道「刚才发生了什么变化」，而不是一张图。
- 需要尽量省 token / 省带宽 / 避免把屏幕内容发到模型。

## 启动

```powershell
cd tools/screen-sense
powershell.exe -NoProfile -ExecutionPolicy Bypass -File daemon.ps1
```

监听 `127.0.0.1:8791`，行式 JSON 协议。

## 调用

```bash
python query.py digest        # 当前摘要（默认预算 220）
python query.py events        # 变更事件
```

或直接发一行 JSON：

```json
{"op":"digest","budget":220}
{"op":"events","since":0}
{"op":"pages","port":9222}
{"op":"region","x":0,"y":0,"w":800,"h":600,"scale":0.5}
{"op":"stop"}
```

## 预算档位（实测）

| budget | tokens | 内容 |
|---|---|---|
| 220 | ~129 | app + title + focus + 窗口列表 |
| 60 | ~55 | 去掉窗口列表 |
| 25 | ~16 | 只剩 app + 截断标题 |

## 按需升级

默认只用摘要（130 token 左右）。只有摘要不够用时，才手动 `region` 截一块：
320×240 的区域约 102 token / 22 ms，整屏 864×576 约 664 token / 146 ms。
截图落盘到 captures/，只保留最近 20 张，可以用 `{"op":"captures","keep":-1}` 清空。

## 行为约定

- 密码框（`IsPassword`）的值一律变成 `[password]`。
- 敏感应用（密码管理器）整条摘要塌缩成 `[blocked]`。
- 不读剪贴板、不落盘、不截屏。

## 已知限制

- Electron/Chromium 应用在 UIA 里常常只暴露窗口层，需要 CDP 补（需浏览器加 `--remote-debugging-port`）。
- 沙箱内跨进程连不上 CDP 端口；插件须在沙箱外运行。

---

出品：**小鲸 & 凌寒**
