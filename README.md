# codex-cc-pet

> A tiny macOS desktop companion for [**codex-plugin-cc**](https://github.com/openai/codex-plugin-cc) — a pet that reacts to your Codex background jobs and notifies you when they finish.

[codex-plugin-cc](https://github.com/openai/codex-plugin-cc) 的桌面伴侣。在 Claude Code 里用该插件把任务派给 Codex 后台跑时,这只宠物会**实时反映任务状态、跑完弹系统通知**——补「后台 job 跑完无感知、得手动 `/codex:status` 查」的缺口。

单一自包含 `.app`:**双击运行,拷到别的 Mac 也直接双击运行**(通用二进制,Intel / Apple Silicon 通吃),不依赖 node、无需安装脚本。

![codex-cc-pet 四种状态](assets/states.svg)

## 前置条件

本工具**只服务于 codex-plugin-cc**(Claude Code × Codex 的插件)。它读取该插件写在本地的 job 状态;**不针对 Codex CLI / Codex 桌面版**——单用那些不会有数据。

- macOS 12+
- 已安装并在用 [codex-plugin-cc](https://github.com/openai/codex-plugin-cc),且通过它派后台任务(`/codex:rescue` 等)

## 用法

- **运行**:双击 `codex-cc-pet.app`(或 `open codex-cc-pet.app`)。
- **移动**:拖窗体背景。
- **退出**:窗体上双击。
- **开机自启**:系统设置 → 通用 → 登录项 → 「+」→ 选 `codex-cc-pet.app`。
- **通知权限**:任务首次跑完弹通知时,系统会问一次,放行即可。

## 行为

每 3 秒只读扫描插件的 job 状态文件(`~/.claude/plugins/data/codex-inline/state/<项目>/state.json`):

| 状态 | 宠物 | 通知 |
|---|---|---|
| 摸鱼(无 job) | 🐤 慢速呼吸浮动 | — |
| 干活(≥1 在跑) | 🐤 加速浮动,气泡显示 **Codex 实时话术** | — |
| 搞定(刚 completed) | 🎉 跳一下(5s) | ✅ 系统通知 + 摘要 |
| 崩了(刚 failed) | 😵 抖动(6s) | ⚠️ 系统通知 + 摘要 |

实时话术取自当前活跃 job 的 `logFile` 尾部最新一条 `Assistant message` 旁白。

## 它怎么工作

![工作流](assets/flow.svg)

## 搬到其他电脑

直接拷 `codex-cc-pet.app` 过去双击。二进制是通用架构,目标机**无需 node、无需 swiftc、无需安装**。

> 首次打开未签名 app 若被 Gatekeeper 拦:右键 → 打开,或「系统设置 → 隐私与安全性 → 仍要打开」。

## 从源码构建

```bash
./build.sh   # 把 codex-cc-pet.swift 编译成通用二进制,放进 codex-cc-pet.app
```

需 Xcode Command Line Tools(`xcode-select --install`,提供 swiftc)。仅开发/构建机需要,分发出去的 `.app` 不需要。

## 文件

| 文件 | 说明 |
|---|---|
| `codex-cc-pet.swift` | 全部源码(原生 AppKit,无第三方依赖) |
| `codex-cc-pet.app` | 可分发应用(`Contents/MacOS/codex-cc-pet` 为编译产物,已 gitignore) |
| `build.sh` | 重建脚本(通用二进制) |

## License

MIT
