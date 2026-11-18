# imeplus.koplugin — 拼音输入增强 / Pinyin IME enhancement for KOReader

> **⚠️ 已停止维护 / DEPRECATED**：本插件已由 [imebar.koplugin（拼音辣条）](https://github.com/eznas/imebar.koplugin) 取代 —— 自带引擎 + 键盘上方候选字条带，可直接替换本插件；两插件同时安装时 imebar 稳定优先。设置数据（`imeplus_*`）与自定义词组不会自动迁移，见 imebar README。
>
> **⚠️ DEPRECATED**: superseded by [imebar.koplugin](https://github.com/eznas/imebar.koplugin) — a self-hosted engine plus a full-width candidate strip above the keyboard. Drop-in replacement; when both are installed imebar takes priority.

让 KOReader 内置拼音输入法好用起来：候选带数字编号、数字键选字、←/→ 翻页、模糊拼音、按输入框宽度自适应候选数、记忆常用词（简拼）。
Makes the built-in KOReader pinyin IME actually usable: numbered candidate window, digit selection, ←/→ paging, fuzzy pinyin, width-aware candidate count, and self-learned abbreviations.

纯插件实现（`require` 接管 + 引擎副本），**不修改任何系统文件**，删目录即卸载。
Pure plugin (engine takeover via `package.preload`), **touches no system files** — delete the folder to uninstall.

## 功能 / Features

- **候选窗口**：舞台字 + `[2你 3尼 …9倪]` 数字编号候选，最多 9 个/页
- **数字选字**：组合中按 1-9 上屏对应候选；超出可见范围的数字按字面上屏
- **←/→ 翻页**：整页翻动，首尾回绕；空格上屏当前页首选
- **模糊拼音（可自定义规则）**：菜单「模糊规则」里逐项勾选 9 对常见易混音——zh/z、ch/c、sh/s（默认开）、n/l、l/r、an/ang、en/eng、in/ing、f/h。查询时变体展开 + 候选合并（原码永远排最前）；总开关也在菜单
- **宽度自适应**：多字词候选按输入框实际宽度动态缩减数量，行首不被滚动裁掉
- **记忆常用词（简拼）**：上屏过的词会被记住，之后可用声母缩写打出。例如完整输入 `jiazai` 上屏「加载」一次，以后打 `jz` 即出；打过 `zhichi` 后，`zhch`/`zc`/`zhc`/`zch` 都能找到「支持」。词按使用次数排序，最多存 200 条（存于 `settings.reader.lua`，无额外文件）；首音节内前缀（`zh`）和残缺全拼（`xuxi`）不算简拼。菜单可开关、可清空
- **自定义词组表（菜单内编辑）**：菜单「自定义词组表」打开文本编辑器，每行一个词；只写词则编码自动从内置词库生成，多音字可写「词 拼音」（如 `氪金 kejin`）。# 开头为注释。保存后下次打开键盘生效，无需重启
- **高频前置**：上屏过的词/自定义词共用同一候选池，**排序只看实际使用次数**（不区分来源）——全拼码下常打的词提到词库候选之前（`chengdu` 首选由 程度 变 成都），简拼下同理；原词库候选顺延保留
- **高频前置**：上屏过的词/自定义词在**全拼码**下也会提到词库候选之前（常打「成都」后 `chengdu` 首选由 程度 变 成都），简拼下按使用次数排序；次数高的历史词压过自定义词，原词库候选顺延保留
- **v 模式**：输入 `v` 开头后直接输出半角英文，`vbing` + 空格 → `bing`。标点/数字/空格提交，退格删字母；不影响正常拼音与 vterm
- **零词库增量**：模糊拼音与记忆词均为查询时计算，无内置词库改动、无新控件

菜单入口：`工具 → 更多工具 → 拼音输入增强`（模糊拼音开关、模糊规则、记忆词、自定义词组表说明、清空记忆词、关于）。

## 安装 / Install

```
koreader/plugins/imeplus.koplugin/   ← 整个目录
├── _meta.lua
├── main.lua
├── ime_engine.lua
└── custom_words.lua        ← 自定义词组表（可编辑，默认空模板）
```

复制到设备 `koreader/plugins/` 下，重启 KOReader 即生效（新版 KOReader 默认启用插件）。

## 兼容性 / Compatibility

- 基准引擎：KOReader **v2025.10** 的 `frontend/ui/data/keyboardlayouts/generic_ime.lua`（md5 3b85fda9…）
- 实测：v2026.07.2（Kindle PaperWhite 3 / Voyage）
- 启动时校验系统引擎尺寸与特征串，**版本不符自动放弃接管**并回退原生输入法（日志 WARN），不会崩溃
- 仅接管简体中文拼音键盘；越南语/笔画布局行为不变
- 与其它拼音增强插件（pinyin_enhancement / pinyinplus / pinyinime）**不可同时启用**
- 兼容 vterm 终端插件的 IME 适配层（KOReader autotest mode4/11/12 全绿）

## 原理 / How it works

KOReader 插件先于键盘加载。启动时把 `require("ui/data/keyboardlayouts/generic_ime")` 重定向到插件自带的引擎副本（stock 快照 + ~120 行功能补丁），所有新增行为由 `switch_char == "→"`（拼音布局标识）门控。组合状态 `_stack` 是引擎模块私有 upvalue，纯方法补丁无法访问，因此采用整副本接管而非类方法补丁。

词库使用 KOReader 内置拼音码表（来自 [rime/rime-pinyin-simp](https://github.com/rime/rime-pinyin-simp)）。

## License

AGPL-3.0（`ime_engine.lua` 衍生自 KOReader 的 generic_ime.lua）。
