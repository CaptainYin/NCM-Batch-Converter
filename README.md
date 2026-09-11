# NCM Batch Converter for Windows

一个轻量、免安装、完全本地运行的 Windows `.ncm` 批量转换工具。

> Batch-decrypt NetEase Cloud Music `.ncm` files and restore the embedded original audio format on Windows.

## 特点

- **免安装**：无需 Python、ffmpeg、Java 或第三方 EXE
- **纯本地处理**：不会上传音频文件
- **批量转换**：支持整个文件夹
- **递归处理**：可扫描子文件夹
- **保持目录结构**
- **自动识别原始音频格式**：常见为 MP3 / FLAC
- **不重新编码**：恢复 NCM 中的原始音频数据，避免二次有损压缩
- **默认不覆盖**：已有同名文件时默认跳过
- **可选删除源文件**：转换成功后可选择删除原 `.ncm`
- **带 GUI**：基于 Windows Forms
- **带启动诊断**：方便定位 PowerShell 环境或脚本解析问题

## 系统要求

- Windows 10 / Windows 11
- Windows PowerShell 5.1 或兼容环境
- 无需管理员权限

## 使用方法

### 方法 1：推荐

1. 下载或克隆本仓库。
2. 确保整个目录已经完整解压。
3. 双击：

```text
NCM-Batch-Converter.cmd
```

4. 选择包含 `.ncm` 文件的文件夹。
5. 选择输出目录。
6. 点击“开始批量转换”。

### 方法 2：生成单文件版 CMD

仓库保留可审阅的 PowerShell 源码，并提供构建脚本生成与 v1.2 发布包同类的自包含单文件启动器：

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-SingleFile.ps1
```

生成：

```text
NCM一键批量转换_单文件版.cmd
```

之后这个 `.cmd` 可以单独复制到其他位置运行，不依赖旁边的 `.ps1`。

### 方法 3：诊断启动问题

如果窗口启动失败，运行：

```text
NCM启动诊断.cmd
```

运行时错误日志默认写入：

```text
%TEMP%\NCM_Batch_Converter_error.log
```

## 输出格式说明

这个工具的默认目标是**恢复 NCM 内部原本的音频格式，而不是强制转码成 MP3**。

因此通常：

| NCM 中原始音频 | 输出 |
|---|---|
| MP3 | `.mp3` |
| FLAC | `.flac` |

脚本也包含对 OGG、WAV、APE、M4A 常见文件头的识别。

如果原始文件是 FLAC，工具不会为了得到 `.mp3` 后缀而重新进行有损编码。

## 为什么不需要 ffmpeg？

NCM 文件中的音频内容本身通常已经是 MP3 或 FLAC，只是被封装和加密。工具负责解析 NCM 容器、恢复音频密钥并解密音频字节，然后根据音频文件头确定扩展名。

因此正常情况下不存在“FLAC → MP3”或“MP3 → MP3”的重新编码过程。

## 安全建议

首次使用时，建议**不要勾选“转换成功后删除原 .ncm”**。

请先确认输出文件能够正常播放，再自行清理源文件。

## 已知问题

Windows PowerShell 会把某些 Unicode 弯引号（例如 `“ ”`）解释为字符串定界符。v1.2 已移除可执行脚本中的这类字符，修复了：

```text
UnexpectedToken: 删除原
```

## 项目结构

```text
NCM-Batch-Converter/
├─ NCM_Batch_Converter.ps1
├─ NCM-Batch-Converter.cmd
├─ Build-SingleFile.ps1
├─ NCM一键批量转换_启动.cmd
├─ NCM启动诊断.cmd
├─ START_NCM_Converter.cmd
├─ README.md
├─ CHANGELOG.md
├─ LICENSE
└─ .gitignore
```

## 隐私

转换过程完全在本地执行。本项目没有遥测、账户登录、网络上传或云端处理逻辑。

## Legal / 使用说明

本项目用于格式互操作、个人备份及处理你**有权访问和转换**的音频文件。请遵守所在地区法律、服务条款以及版权规定。项目作者不鼓励或授权侵犯版权或未经授权传播受保护内容。

## License

MIT License. See [LICENSE](LICENSE).

---

### English

This is a small, self-contained Windows utility for batch-restoring audio stored in `.ncm` containers.

It uses built-in Windows PowerShell/.NET components only. No Python, ffmpeg, Java, external executable, network service, or upload is required.

The converter restores the embedded source audio rather than transcoding it. An NCM containing MP3 normally becomes `.mp3`; one containing FLAC becomes `.flac`.

Use it only with files you are authorized to access and convert.
