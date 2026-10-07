# PDF Translation Popup for KOReader / PDF 中文弹窗

[English](#english) · [中文](#中文)

```text
pdftranslationpopup.koplugin/   KOReader plugin / KOReader 插件
helpers/                      Desktop PDF converter / 电脑端 PDF 转换工具
LICENSE                       GNU AGPL v3
```

## English

Version **2.4.1** adds tappable popup notes, Chinese translations, and movable dots or OpenMoji faces to PDFs. The plugin interface is currently in Chinese. It displays text you enter or notes already stored in the PDF; it does not translate automatically.

### Install the plugin

1. Download this repository using **Code → Download ZIP** and extract it, or clone the repository.
2. Copy only the **`pdftranslationpopup.koplugin` folder** into your KOReader `plugins/` directory. The path must be `koreader/plugins/pdftranslationpopup.koplugin/main.lua`.
3. Restart KOReader and open a PDF. Find **PDF 中文弹窗** in the document menu.

### Use it

- Turn off PDF text reflow.
- Select **添加圆点模式 → 进入／退出添加模式**, tap the page, and enter a note. Select **表情…** to choose a face.
- Tap a marker to read its popup. In add mode, tap a marker to edit its text or face.
- Long-press a marker, then tap a new position on the same page to move it.
- Close the document normally to embed changes before sharing the PDF. Pending edits are saved in the KOReader sidecar while the document is open. Adding or embedding edits requires a writable PDF.

To convert existing PDF text-note annotations on your computer, use the [helper instructions in English and Chinese](helpers/README.md). Conversion is optional when adding notes directly in KOReader. Recipients need this plugin to see its custom markers and popups.

See [detailed plugin behavior and storage format](pdftranslationpopup.koplugin/README.md).

## 中文

版本 **2.4.1**：在 KOReader 中为 PDF 添加可点击的文字弹窗、中文译文，以及可移动的圆点或 OpenMoji 表情。插件界面目前为中文。插件显示你输入的文字或 PDF 已有的注释，**不会自动翻译**。

### 安装插件

1. 点击 **Code → Download ZIP** 下载本仓库并解压，或克隆仓库。
2. 只将 **`pdftranslationpopup.koplugin` 文件夹**复制到 KOReader 的 `plugins/` 目录。最终路径应为 `koreader/plugins/pdftranslationpopup.koplugin/main.lua`。
3. 重启 KOReader，打开 PDF，在文档菜单中找到 **PDF 中文弹窗**。

### 使用方法

- 关闭 PDF 文字重排。
- 选择 **添加圆点模式 → 进入／退出添加模式**，点击页面并输入注释；点击 **表情…** 可选择表情。
- 点击圆点或表情查看弹窗；在添加模式下点击已有标记，可编辑文字或表情。
- 长按标记，再点击同一页的新位置，即可移动标记。
- 分享 PDF 前，请正常关闭文档，将改动写入 PDF。文档打开期间，待写入改动保存在 KOReader 的 sidecar 中。添加注释和写入改动需要 PDF 文件可写。

如需在电脑上转换 PDF 已有的文字便笺注释，请阅读 [转换工具中英文说明](helpers/README.md)。直接在 KOReader 中添加注释时，无需先转换。接收者需要安装本插件，才能显示这些自定义标记和弹窗。

更多细节见 [插件交互与存储格式说明](pdftranslationpopup.koplugin/README.md)。

## License / 许可

Plugin and helper source retain the original repository's [GNU AGPL v3 license](LICENSE). The plugin was extracted from [rubyxs/koreader](https://github.com/rubyxs/koreader/tree/6ddffef2583fab5f172d4b2663f86e96ee965354/plugins/pdftranslationpopup.koplugin); the converter comes from its `tools/popupconverter/` directory. The 126 bundled OpenMoji SVGs are separately licensed under CC BY-SA 4.0; see [artwork attribution](pdftranslationpopup.koplugin/OPENMOJI.md).

插件及辅助工具代码沿用原仓库的 [GNU AGPL v3 许可](LICENSE)。126 个 OpenMoji SVG 图案单独采用 CC BY-SA 4.0 许可，详见 [图案来源与署名](pdftranslationpopup.koplugin/OPENMOJI.md)。
