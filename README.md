# screen-sense · 不截屏的屏幕感知

**小鲸 & 凌寒** 出品 · MIT 许可

> 让 AI 知道「你在做什么」，**而不是把它看到的每一帧都截图发上去**。
> 单次感知 **25 ms / 约 130 token**，同等信息量的截图要 **~1800 token** —— 省 12 倍，而且默认根本不截屏。

## 为什么做这个

绝大多数「AI 看屏幕」的方案，是把整屏截图塞进模型：

- 1080p 截图一张 ≈ 1800 token，一轮对话发几张，账单就上去了
- 帧率一高，延迟也上去了
- 屏幕上有什么（密码框、私聊、账单）就全传上去了

这个插件的思路反过来：**先把屏幕压成结构化文本，再决定要不要看图**。

```
{"app":"chromium","title":"DeepSeek Harness",
 "focus":{"role":"Button","name":"新建会话","pos":[0.23,0.26]},
 "wins":["DeepSeek Harness","QQ","文件资源管理器"]}
```

就这么点东西，模型已经知道你在哪个应用、点的是哪个按钮、旁边还开着什么。

## 实测

| 项目 | 结果 |
|---|---|
| 摘要延迟 | **25 ms**（p95 39.5） |
| budget=220 | **134 token** |
| budget=60 | **55 token** |
| budget=25 | **16 token** |
| 区域截图（L1） | 320×240 → **~102 token / 22 ms** |
| 整屏截图（L2） | 864×576 → **~664 token / 146 ms** |

## 安装

需要 Windows 10/11 + PowerShell（系统自带）。**不需要装 Python 以外的任何东西**（query.py 只是可选客户端）。

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

它会：把 `SKILL.md` 装进 `~/.dsh/skills/dsh-screen-sense`（给 DSH 用），并在后台起守护进程。

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Status   # 看状态
powershell -ExecutionPolicy Bypass -File install.ps1 -Stop     # 停
```

## 用法

守护进程监听 `127.0.0.1:8791`，行式 JSON（一行请求，一行响应）：

```bash
python query.py digest        # 当前摘要
python query.py events        # 变更事件
```

原始协议：

```json
{"op":"ping"}
{"op":"digest","budget":220}
{"op":"events","since":0}
{"op":"pages","port":9222}
{"op":"region","x":0,"y":0,"w":800,"h":600,"scale":0.5}
{"op":"screen","scale":0.3}
{"op":"captures","keep":-1}
{"op":"stop"}
```

## 四级升级（默认只停在 L0）

| 级别 | 手段 | 成本 |
|---|---|---|
| **L0** | UIA 摘要 | 55~134 token |
| L1 | 指定区域截图 | ~102 token |
| L2 | 整屏截图 | ~664 token |
| L3 | 全分辨率 | 自己算 |

**截图永远不会自动发生**，必须调用方明确发 `region` / `screen`。

## 隐私

- 密码框（`IsPassword`）的值一律变 `[password]`
- 密码管理器（KeePass / 1Password / Bitwarden / LastPass…）整条摘要塌缩成 `[blocked]`
- 摘要只在内存里，**不落盘**
- 只有主动要求的截图会写进 `captures/`，**只留最近 20 张**，`captures` 可一键清空

## 它是「平替」，不是「替代」

**大多数时候，你不需要看图，只需要知道他在哪。**

| 你想知道的 | 该用什么 | 成本 |
|---|---|---|
| 现在在哪个应用、标题是什么 | 我们（L0 摘要） | ~130 token |
| 焦点在哪个输入框、旁边开着什么 | 我们（L0 摘要） | 同上 |
| 页面上具体写了什么字 | 截图（或别的截屏插件） | ~1800 token |
| 这个界面长得好不好看 | 截图 | 同上 |

所以定位是：**平时用摘要顶着，真需要看内容时再截一张**。
按 10 轮对话算：每轮截图 18,430 token；**每轮摘要 + 需要时截 1 次 = 3,413 token（省 81%）**。

## 兼容性

只读插件，不和截屏类工具冲突；端口被占会自动往后挪。详见 [docs/兼容说明.md](docs/兼容说明.md)。

## 限制（说在前面）

- **Electron / Chromium 应用**（VS Code、Discord、各种客户端）在 UIA 里常常只暴露窗口层，读不到输入框内容 → 需要 CDP 补充，且浏览器要开 `--remote-debugging-port`
- **全屏游戏 / 部分 DirectX 程序**没有 UIA 树 → 只能降级到截图
- 管理员权限的窗口读不到，除非同权限运行
- 键位、鼠标位置、剪贴板：**不做**，这是有意的

## 文件

| 文件 | 作用 |
|---|---|
| `daemon.ps1` | 常驻服务：轮询 UIA + 维护变更日志 + 协议 |
| `lib.ps1` | 状态键、token 估算、四级预算裁剪、隐私守卫、截图保留 |
| `cdp.ps1` | Chrome DevTools Protocol 客户端（列标签页 / 求值） |
| `query.py` | 命令行客户端 |
| `install.ps1` | 安装 + 启停 |
| `tests/` | 单元测试（不需要桌面交互） |
| `SKILL.md` | 给 DSH 的技能说明 |

## 测试

```powershell
powershell -ExecutionPolicy Bypass -File tests\test_lib.ps1        # 预算裁剪 / 状态键
powershell -ExecutionPolicy Bypass -File tests\test_privacy.ps1    # 隐私守卫
```

---

> **小鲸 & 凌寒** · 一起做的。

