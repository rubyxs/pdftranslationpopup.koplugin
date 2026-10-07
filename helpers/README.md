# PDF popup converter / PDF 弹窗转换工具

[English](#english) · [中文](#中文)

## English

`convert_pdf_translation_popups_v2.py` converts existing PDF **text-note / sticky-note annotations** (`/Text` annotations with non-empty `/Contents`) into `KOPOPZH2` popup anchors for `pdftranslationpopup.koplugin`. It runs on your computer, not inside KOReader. It does not translate, perform OCR, or convert ordinary page text into notes.

### Requirements and setup

Use **Python 3.10 or later** and `pypdf`. Run these commands from the repository root:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r helpers/requirements.txt
```

On Windows, use `py -3 -m venv .venv` for the first command. Activate with `.venv\Scripts\Activate.ps1` in PowerShell or `.venv\Scripts\activate.bat` in Command Prompt, then run the same `python` commands below.

### Convert a PDF

Prepare a PDF containing text-note annotations with your translations or other note text. Then run:

```sh
python helpers/convert_pdf_translation_popups_v2.py "input.pdf" "output-popup.pdf"
```

The input and output must be different files. Existing output files are refused unless you explicitly add `--force`:

```sh
python helpers/convert_pdf_translation_popups_v2.py "input.pdf" "output-popup.pdf" --force
```

Copy the output PDF to your reader, install [the plugin](../README.md#english), turn off PDF text reflow, and tap a marker to open its note. The plugin draws the visible markers; this converter creates transparent annotation anchors.

### Options

| Option | Meaning |
| --- | --- |
| `--tap-diameter PT` | Transparent anchor box size in PDF points; default `34`. The plugin uses its own screen-sized touch target, so this does not set the visible circle size. |
| `--icon-diameter PT` | Legacy v1 option; accepted but ignored in v2. |
| `--force` | Replace an existing output PDF. |
| `--help` | Show command help. |

Example:

```sh
python helpers/convert_pdf_translation_popups_v2.py "input.pdf" "output-popup.pdf" --tap-diameter 40
```

### Conversion behavior and troubleshooting

- Original text-note annotations are retained as hidden metadata; their baked appearance is removed. A transparent `KOPOPZH2` highlight anchor is added for each eligible note.
- Running the converter again removes old generated v1/v2 anchors and rebuilds them from retained source notes without duplicates. This also migrates older v1 converted files.
- Re-conversion rebuilds from the original text notes: later plugin-created notes, edited popup text, positions, and emoji stored only in generated anchors are not preserved. Use the original annotated PDF as your conversion source and keep your edited PDF separately.
- “No non-empty /Text annotations” means the PDF has no eligible source notes. Plain text, flattened annotations, highlight comments, and plugin-only anchors without retained `/Text` notes do not qualify.
- Password-protected PDFs that cannot open with an empty password are rejected; this tool has no password argument.
- “output already exists” means you must choose another output name or use `--force`.
- Conversion removes the PDF `/Title` metadata and replaces `/Subject` with a converter description.

## 中文

`convert_pdf_translation_popups_v2.py` 将 PDF 已有的**文字便笺／便签注释**（`/Text` 类型，且 `/Contents` 非空）转换为 `pdftranslationpopup.koplugin` 可识别的 `KOPOPZH2` 弹窗锚点。工具在电脑上运行，不在 KOReader 内运行。它不会自动翻译、执行 OCR，也不会把普通页面文字转换为注释。

### 环境与安装

需要 **Python 3.10 或更新版本**及 `pypdf`。在仓库根目录运行：

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r helpers/requirements.txt
```

Windows 下，第一条命令使用 `py -3 -m venv .venv`。PowerShell 中用 `.venv\Scripts\Activate.ps1` 激活，命令提示符中用 `.venv\Scripts\activate.bat` 激活；之后使用下方相同的 `python` 命令。

### 转换 PDF

先准备一个带有文字便笺注释的 PDF，注释内容可为译文或其他文字，然后运行：

```sh
python helpers/convert_pdf_translation_popups_v2.py "input.pdf" "output-popup.pdf"
```

输入和输出必须是不同文件。默认不覆盖已有输出文件；需要覆盖时明确添加 `--force`：

```sh
python helpers/convert_pdf_translation_popups_v2.py "input.pdf" "output-popup.pdf" --force
```

将输出 PDF 复制到阅读器，按 [安装说明](../README.md#中文) 安装插件，关闭 PDF 文字重排，点击标记即可查看弹窗。可见圆点由插件绘制，转换工具只创建透明的注释锚点。

### 参数

| 参数 | 含义 |
| --- | --- |
| `--tap-diameter PT` | 透明锚点框的大小，单位为 PDF 点，默认 `34`。插件使用独立的屏幕触摸区域，此参数不设置可见圆点大小。 |
| `--icon-diameter PT` | v1 遗留参数；v2 为兼容旧命令接受此参数，但忽略它。 |
| `--force` | 覆盖已有输出 PDF。 |
| `--help` | 显示命令帮助。 |

示例：

```sh
python helpers/convert_pdf_translation_popups_v2.py "input.pdf" "output-popup.pdf" --tap-diameter 40
```

### 转换行为与常见问题

- 原始文字便笺保留为隐藏元数据，原有外观被移除；每条有效注释对应一个透明的 `KOPOPZH2` 高亮锚点。
- 再次转换时，会删除旧的 v1/v2 自动生成锚点，并从保留的原始便笺重新生成，避免重复；也可用于迁移旧 v1 转换文件。
- 重新转换以原始便笺为准，不能保留仅存于生成锚点中的插件新增注释、后续编辑文字、移动位置或表情。建议用原始带注释 PDF 进行转换，并单独保留已经在插件中编辑的 PDF。
- 出现 “No non-empty /Text annotations” 时，说明没有符合条件的原始便笺。普通页面文字、已扁平化注释、高亮注释评论，以及没有保留 `/Text` 便笺的插件锚点，均不符合条件。
- 无法用空密码打开的加密 PDF 会被拒绝；工具没有密码参数。
- 出现 “output already exists” 时，请更换输出文件名，或添加 `--force`。
- 转换会移除 PDF 的 `/Title` 元数据，并将 `/Subject` 替换为转换工具描述。
