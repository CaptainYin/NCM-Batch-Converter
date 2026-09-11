param(
    [string]$InitialPath = ""
)

$ErrorActionPreference = "Stop"
$script:CrashLog = Join-Path $env:TEMP "NCM_Batch_Converter_error.log"

trap {
    try {
        $msg = @(
            "NCM Batch Converter startup/runtime error"
            ("Time: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
            ("PowerShell: " + $PSVersionTable.PSVersion.ToString())
            ("Message: " + $_.Exception.Message)
            ("Position: " + $_.InvocationInfo.PositionMessage)
            ("ScriptStackTrace: " + $_.ScriptStackTrace)
        ) -join [Environment]::NewLine

        [System.IO.File]::WriteAllText(
            $script:CrashLog,
            $msg,
            (New-Object System.Text.UTF8Encoding($true))
        )

        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            [System.Windows.Forms.MessageBox]::Show(
                "程序发生错误。错误日志已保存到：`r`n" + $script:CrashLog + "`r`n`r`n" + $_.Exception.Message,
                "NCM 批量转换器 - 错误",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        } catch {}
    } catch {}
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# Self-contained NCM decoder.
# No Python / ffmpeg / third-party EXE is required.
$csharp = @'
using System;
using System.IO;
using System.Text;
using System.Security.Cryptography;

public sealed class NcmDecodeResult
{
    public string OutputPath;
    public string Format;
    public bool Skipped;
    public long BytesWritten;
}

public static class NcmDecoder
{
    private static readonly byte[] CoreKey = new byte[] {
        0x68,0x7A,0x48,0x52,0x41,0x6D,0x73,0x6F,
        0x35,0x6B,0x49,0x6E,0x62,0x61,0x78,0x57
    };

    private static byte[] ReadExact(BinaryReader br, int count, string what)
    {
        byte[] data = br.ReadBytes(count);
        if (data.Length != count)
            throw new InvalidDataException("文件损坏：无法完整读取 " + what + "。");
        return data;
    }

    private static byte[] AesEcbDecrypt(byte[] input, byte[] key)
    {
        if (input == null || input.Length == 0 || (input.Length % 16) != 0)
            throw new InvalidDataException("文件损坏：AES 数据长度异常。");

        byte[] output;
        using (Aes aes = Aes.Create())
        {
            aes.KeySize = 128;
            aes.BlockSize = 128;
            aes.Mode = CipherMode.ECB;
            aes.Padding = PaddingMode.None;
            aes.Key = key;

            using (ICryptoTransform dec = aes.CreateDecryptor())
            {
                output = dec.TransformFinalBlock(input, 0, input.Length);
            }
        }

        int pad = output[output.Length - 1];
        if (pad >= 1 && pad <= 16)
        {
            byte[] unpadded = new byte[output.Length - pad];
            Buffer.BlockCopy(output, 0, unpadded, 0, unpadded.Length);
            return unpadded;
        }
        return output;
    }

    private static byte[] BuildKeyBox(byte[] key)
    {
        if (key == null || key.Length == 0)
            throw new InvalidDataException("文件损坏：音频密钥为空。");

        byte[] box = new byte[256];
        for (int i = 0; i < 256; i++)
            box[i] = (byte)i;

        int last = 0;
        int keyOffset = 0;

        for (int i = 0; i < 256; i++)
        {
            int swap = box[i];
            int c = (swap + last + key[keyOffset]) & 0xFF;

            keyOffset++;
            if (keyOffset >= key.Length)
                keyOffset = 0;

            box[i] = box[c];
            box[c] = (byte)swap;
            last = c;
        }

        return box;
    }

    private static byte[] BuildStreamPattern(byte[] box)
    {
        byte[] pattern = new byte[256];
        for (int i = 0; i < 256; i++)
        {
            int j = (i + 1) & 0xFF;
            int idx = (box[j] + j) & 0xFF;
            int k = (box[j] + box[idx]) & 0xFF;
            pattern[i] = box[k];
        }
        return pattern;
    }

    private static void DecryptBuffer(byte[] buffer, int count, byte[] pattern, long audioOffset)
    {
        for (int i = 0; i < count; i++)
            buffer[i] = (byte)(buffer[i] ^ pattern[(int)((audioOffset + i) & 0xFF)]);
    }

    private static bool StartsWith(byte[] b, int count, params byte[] p)
    {
        if (count < p.Length) return false;
        for (int i = 0; i < p.Length; i++)
            if (b[i] != p[i]) return false;
        return true;
    }

    private static string DetectFormat(byte[] buffer, int count)
    {
        if (count >= 3 && buffer[0] == 0x49 && buffer[1] == 0x44 && buffer[2] == 0x33)
            return "mp3";

        if (count >= 2 && buffer[0] == 0xFF && (buffer[1] & 0xE0) == 0xE0)
            return "mp3";

        if (StartsWith(buffer, count, 0x66,0x4C,0x61,0x43))
            return "flac";

        if (StartsWith(buffer, count, 0x4F,0x67,0x67,0x53))
            return "ogg";

        if (count >= 12 &&
            buffer[0] == 0x52 && buffer[1] == 0x49 &&
            buffer[2] == 0x46 && buffer[3] == 0x46 &&
            buffer[8] == 0x57 && buffer[9] == 0x41 &&
            buffer[10] == 0x56 && buffer[11] == 0x45)
            return "wav";

        if (StartsWith(buffer, count, 0x4D,0x41,0x43,0x20))
            return "ape";

        if (count >= 8 &&
            buffer[4] == 0x66 && buffer[5] == 0x74 &&
            buffer[6] == 0x79 && buffer[7] == 0x70)
            return "m4a";

        return "flac";
    }

    public static NcmDecodeResult Decode(string inputPath, string outputDir, bool overwrite)
    {
        if (String.IsNullOrWhiteSpace(inputPath))
            throw new ArgumentException("输入文件为空。");
        if (!File.Exists(inputPath))
            throw new FileNotFoundException("找不到 NCM 文件。", inputPath);

        Directory.CreateDirectory(outputDir);
        string tempPath = null;

        try
        {
            using (FileStream fs = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (BinaryReader br = new BinaryReader(fs))
            {
                byte[] magic = ReadExact(br, 8, "NCM 文件头");
                string magicText = Encoding.ASCII.GetString(magic);
                if (magicText != "CTENFDAM")
                    throw new InvalidDataException("不是有效的 NCM 文件（文件头不匹配）。");

                ReadExact(br, 2, "保留字段");

                uint keyLenU = br.ReadUInt32();
                if (keyLenU == 0 || keyLenU > 1024 * 1024)
                    throw new InvalidDataException("文件损坏：密钥长度异常。");
                int keyLen = (int)keyLenU;

                byte[] encryptedKey = ReadExact(br, keyLen, "加密密钥");
                for (int i = 0; i < encryptedKey.Length; i++)
                    encryptedKey[i] ^= 0x64;

                byte[] rawKey = AesEcbDecrypt(encryptedKey, CoreKey);
                if (rawKey.Length <= 17)
                    throw new InvalidDataException("文件损坏：无法解析音频密钥。");

                byte[] key = new byte[rawKey.Length - 17];
                Buffer.BlockCopy(rawKey, 17, key, 0, key.Length);

                byte[] keyBox = BuildKeyBox(key);
                byte[] pattern = BuildStreamPattern(keyBox);

                uint metaLenU = br.ReadUInt32();
                if (metaLenU > 64 * 1024 * 1024)
                    throw new InvalidDataException("文件损坏：元数据长度异常。");
                if (metaLenU > 0)
                    ReadExact(br, (int)metaLenU, "元数据");

                ReadExact(br, 5, "CRC/封面版本");
                uint coverFrameLen = br.ReadUInt32();
                uint imageLen = br.ReadUInt32();

                if (imageLen > coverFrameLen)
                    throw new InvalidDataException("文件损坏：封面长度字段异常。");
                if ((long)coverFrameLen > fs.Length - fs.Position)
                    throw new InvalidDataException("文件损坏：封面区超出文件长度。");

                fs.Seek((long)coverFrameLen, SeekOrigin.Current);

                if (fs.Position >= fs.Length)
                    throw new InvalidDataException("文件损坏：找不到音频数据。");

                byte[] buffer = new byte[1024 * 1024];
                int firstCount = fs.Read(buffer, 0, buffer.Length);
                if (firstCount <= 0)
                    throw new InvalidDataException("文件损坏：音频数据为空。");

                DecryptBuffer(buffer, firstCount, pattern, 0);
                string format = DetectFormat(buffer, firstCount);

                string baseName = Path.GetFileNameWithoutExtension(inputPath);
                string outputPath = Path.Combine(outputDir, baseName + "." + format);

                if (File.Exists(outputPath) && !overwrite)
                {
                    return new NcmDecodeResult {
                        OutputPath = outputPath,
                        Format = format,
                        Skipped = true,
                        BytesWritten = 0
                    };
                }

                tempPath = Path.Combine(
                    outputDir,
                    "." + baseName + "." + Guid.NewGuid().ToString("N") + ".ncmdecode.tmp"
                );

                long written = 0;
                using (FileStream output = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    output.Write(buffer, 0, firstCount);
                    written += firstCount;

                    long audioOffset = firstCount;
                    while (true)
                    {
                        int n = fs.Read(buffer, 0, buffer.Length);
                        if (n <= 0) break;

                        DecryptBuffer(buffer, n, pattern, audioOffset);
                        output.Write(buffer, 0, n);
                        written += n;
                        audioOffset += n;
                    }
                    output.Flush();
                }

                if (written <= 0)
                    throw new InvalidDataException("转换失败：输出音频为空。");

                if (File.Exists(outputPath))
                    File.Delete(outputPath);

                File.Move(tempPath, outputPath);
                tempPath = null;

                return new NcmDecodeResult {
                    OutputPath = outputPath,
                    Format = format,
                    Skipped = false,
                    BytesWritten = written
                };
            }
        }
        catch
        {
            if (!String.IsNullOrEmpty(tempPath))
            {
                try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { }
            }
            throw;
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "转换核心初始化失败：`r`n" + $_.Exception.Message,
        "NCM 批量转换器",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

function Normalize-InitialFolder([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Split-Path -LiteralPath $path -Parent)
        }
        if (Test-Path -LiteralPath $path -PathType Container) {
            return (Get-Item -LiteralPath $path).FullName
        }
    } catch {}
    return ""
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "NCM 一键批量转换器"
$form.Size = New-Object System.Drawing.Size(780, 610)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.AllowDrop = $true
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "NCM 一键批量转换器"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 18)
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "批量解密网易云音乐 .ncm，自动恢复为原始 MP3 / FLAC；不转码、不损失音质。"
$sub.AutoSize = $true
$sub.Location = New-Object System.Drawing.Point(26, 55)
$form.Controls.Add($sub)

$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Text = "NCM 文件夹："
$lblSource.AutoSize = $true
$lblSource.Location = New-Object System.Drawing.Point(26, 98)
$form.Controls.Add($lblSource)

$txtSource = New-Object System.Windows.Forms.TextBox
$txtSource.Location = New-Object System.Drawing.Point(126, 94)
$txtSource.Size = New-Object System.Drawing.Size(510, 26)
$form.Controls.Add($txtSource)

$btnSource = New-Object System.Windows.Forms.Button
$btnSource.Text = "浏览..."
$btnSource.Location = New-Object System.Drawing.Point(650, 92)
$btnSource.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($btnSource)

$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text = "输出文件夹："
$lblOutput.AutoSize = $true
$lblOutput.Location = New-Object System.Drawing.Point(26, 143)
$form.Controls.Add($lblOutput)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location = New-Object System.Drawing.Point(126, 139)
$txtOutput.Size = New-Object System.Drawing.Size(510, 26)
$form.Controls.Add($txtOutput)

$btnOutput = New-Object System.Windows.Forms.Button
$btnOutput.Text = "浏览..."
$btnOutput.Location = New-Object System.Drawing.Point(650, 137)
$btnOutput.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($btnOutput)

$chkRecursive = New-Object System.Windows.Forms.CheckBox
$chkRecursive.Text = "包含子文件夹"
$chkRecursive.Checked = $true
$chkRecursive.AutoSize = $true
$chkRecursive.Location = New-Object System.Drawing.Point(30, 188)
$form.Controls.Add($chkRecursive)

$chkOverwrite = New-Object System.Windows.Forms.CheckBox
$chkOverwrite.Text = "覆盖已存在的同名音频"
$chkOverwrite.Checked = $false
$chkOverwrite.AutoSize = $true
$chkOverwrite.Location = New-Object System.Drawing.Point(175, 188)
$form.Controls.Add($chkOverwrite)

$chkDelete = New-Object System.Windows.Forms.CheckBox
$chkDelete.Text = "转换成功后删除原 .ncm"
$chkDelete.Checked = $false
$chkDelete.AutoSize = $true
$chkDelete.Location = New-Object System.Drawing.Point(380, 188)
$form.Controls.Add($chkDelete)

$note = New-Object System.Windows.Forms.Label
$note.Text = "提示：建议先不要勾选【删除原 .ncm】，确认转换结果正常后再清理源文件。"
$note.AutoSize = $true
$note.ForeColor = [System.Drawing.Color]::DimGray
$note.Location = New-Object System.Drawing.Point(28, 219)
$form.Controls.Add($note)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "开始批量转换"
$btnStart.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$btnStart.Location = New-Object System.Drawing.Point(29, 253)
$btnStart.Size = New-Object System.Drawing.Size(145, 38)
$form.Controls.Add($btnStart)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = "打开输出目录"
$btnOpen.Location = New-Object System.Drawing.Point(188, 253)
$btnOpen.Size = New-Object System.Drawing.Size(125, 38)
$form.Controls.Add($btnOpen)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(330, 257)
$progress.Size = New-Object System.Drawing.Size(410, 28)
$progress.Minimum = 0
$progress.Maximum = 1
$form.Controls.Add($progress)

$status = New-Object System.Windows.Forms.Label
$status.Text = "等待开始"
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(29, 306)
$form.Controls.Add($status)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ScrollBars = "Vertical"
$log.ReadOnly = $true
$log.WordWrap = $false
$log.Location = New-Object System.Drawing.Point(29, 333)
$log.Size = New-Object System.Drawing.Size(711, 210)
$log.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($log)

function Append-Log([string]$text) {
    $log.AppendText($text + [Environment]::NewLine)
    $log.SelectionStart = $log.Text.Length
    $log.ScrollToCaret()
}

function Set-SourceFolder([string]$folder) {
    if ([string]::IsNullOrWhiteSpace($folder)) { return }
    $txtSource.Text = $folder
    $txtOutput.Text = Join-Path $folder "Converted"
}

$initialFolder = Normalize-InitialFolder $InitialPath
if ($initialFolder) { Set-SourceFolder $initialFolder }

$btnSource.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "选择包含 .ncm 文件的文件夹"
    $dlg.ShowNewFolderButton = $false
    if ($txtSource.Text -and (Test-Path -LiteralPath $txtSource.Text -PathType Container)) {
        $dlg.SelectedPath = $txtSource.Text
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-SourceFolder $dlg.SelectedPath
    }
})

$btnOutput.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "选择转换后音频的保存位置"
    $dlg.ShowNewFolderButton = $true
    if ($txtOutput.Text -and (Test-Path -LiteralPath $txtOutput.Text -PathType Container)) {
        $dlg.SelectedPath = $txtOutput.Text
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtOutput.Text = $dlg.SelectedPath
    }
})

$form.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    } else {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
})

$form.Add_DragDrop({
    param($sender, $e)
    try {
        $paths = [string[]]$e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        if ($paths.Count -gt 0) {
            $folder = Normalize-InitialFolder $paths[0]
            if ($folder) { Set-SourceFolder $folder }
        }
    } catch {}
})

$btnOpen.Add_Click({
    $out = $txtOutput.Text.Trim()
    if ($out -and (Test-Path -LiteralPath $out -PathType Container)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList ('"{0}"' -f $out)
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "输出目录还不存在。",
            "NCM 批量转换器",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
})

$btnStart.Add_Click({
    $source = $txtSource.Text.Trim()
    $output = $txtOutput.Text.Trim()

    if (-not $source -or -not (Test-Path -LiteralPath $source -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            "请先选择有效的 NCM 文件夹。",
            "NCM 批量转换器",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    if (-not $output) {
        $output = Join-Path $source "Converted"
        $txtOutput.Text = $output
    }

    try {
        $source = (Get-Item -LiteralPath $source).FullName.TrimEnd('\')
        [System.IO.Directory]::CreateDirectory($output) | Out-Null
        $output = (Get-Item -LiteralPath $output).FullName.TrimEnd('\')
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "无法创建或访问输出目录：`r`n" + $_.Exception.Message,
            "NCM 批量转换器",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $btnStart.Enabled = $false
    $btnSource.Enabled = $false
    $btnOutput.Enabled = $false
    $chkRecursive.Enabled = $false
    $chkOverwrite.Enabled = $false
    $chkDelete.Enabled = $false
    $log.Clear()

    try {
        Append-Log ("扫描：{0}" -f $source)

        if ($chkRecursive.Checked) {
            $files = @(Get-ChildItem -LiteralPath $source -Filter *.ncm -File -Recurse -ErrorAction Stop)
        } else {
            $files = @(Get-ChildItem -LiteralPath $source -Filter *.ncm -File -ErrorAction Stop)
        }

        $outputPrefix = $output.TrimEnd('\') + '\'
        $files = @($files | Where-Object {
            -not $_.FullName.StartsWith($outputPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        })

        if ($files.Count -eq 0) {
            $status.Text = "没有找到 .ncm 文件"
            Append-Log "没有找到 .ncm 文件。"
            [System.Windows.Forms.MessageBox]::Show(
                "所选目录中没有找到 .ncm 文件。",
                "NCM 批量转换器",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        $progress.Minimum = 0
        $progress.Maximum = $files.Count
        $progress.Value = 0

        $ok = 0
        $skip = 0
        $fail = 0
        $deleted = 0
        $sourcePrefix = $source.TrimEnd('\') + '\'

        Append-Log ("找到 {0} 个 NCM 文件。" -f $files.Count)
        Append-Log ""

        for ($i = 0; $i -lt $files.Count; $i++) {
            $file = $files[$i]
            $status.Text = "正在转换 $($i + 1) / $($files.Count)：$($file.Name)"
            [System.Windows.Forms.Application]::DoEvents()

            try {
                $parent = $file.DirectoryName
                $relativeDir = ""

                if ($parent.Equals($source, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relativeDir = ""
                } elseif ($parent.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relativeDir = $parent.Substring($sourcePrefix.Length)
                }

                $targetDir = $output
                if ($relativeDir) { $targetDir = Join-Path $output $relativeDir }
                [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null

                $result = [NcmDecoder]::Decode(
                    $file.FullName,
                    $targetDir,
                    [bool]$chkOverwrite.Checked
                )

                if ($result.Skipped) {
                    $skip++
                    Append-Log ("[跳过] {0} -> 已存在 {1}" -f $file.Name, $result.OutputPath)
                } else {
                    $ok++
                    $sizeMB = [Math]::Round($result.BytesWritten / 1MB, 2)
                    Append-Log ("[完成] {0} -> {1}  ({2}, {3} MB)" -f `
                        $file.Name, $result.OutputPath, $result.Format.ToUpper(), $sizeMB)

                    if ($chkDelete.Checked) {
                        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                        $deleted++
                    }
                }
            }
            catch {
                $fail++
                Append-Log ("[失败] {0} -> {1}" -f $file.FullName, $_.Exception.Message)
            }

            $progress.Value = $i + 1
            [System.Windows.Forms.Application]::DoEvents()
        }

        $status.Text = "完成：成功 $ok，跳过 $skip，失败 $fail"
        Append-Log ""
        Append-Log ("转换结束：成功 {0}，跳过 {1}，失败 {2}。" -f $ok, $skip, $fail)
        if ($chkDelete.Checked) {
            Append-Log ("已删除原 NCM：{0} 个。" -f $deleted)
        }

        $icon = if ($fail -eq 0) {
            [System.Windows.Forms.MessageBoxIcon]::Information
        } else {
            [System.Windows.Forms.MessageBoxIcon]::Warning
        }

        [System.Windows.Forms.MessageBox]::Show(
            ("转换完成！`r`n`r`n成功：{0}`r`n跳过：{1}`r`n失败：{2}`r`n`r`n输出目录：`r`n{3}" -f `
                $ok, $skip, $fail, $output),
            "NCM 批量转换器",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            $icon
        ) | Out-Null
    }
    catch {
        $status.Text = "发生错误"
        Append-Log ("[错误] " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "NCM 批量转换器",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $btnStart.Enabled = $true
        $btnSource.Enabled = $true
        $btnOutput.Enabled = $true
        $chkRecursive.Enabled = $true
        $chkOverwrite.Enabled = $true
        $chkDelete.Enabled = $true
    }
})

[void]$form.ShowDialog()
