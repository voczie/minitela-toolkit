# Minitela - tray + atalho global (tecla MINITELA do R15M) para trocar de tela.
# Fala com o dispositivo via serial diretamente deste processo PowerShell
# (System.IO.Ports.SerialPort), sem abrir um .exe novo por comando -- isso
# evita tanto o bloqueio do Device Guard em executaveis novos quanto a
# lentidao de reconectar/handshake a cada clique.

$ErrorActionPreference = "SilentlyContinue"

$WorkDir  = Join-Path $env:USERPROFILE "ahmi-work"
$Device   = "COM3"
$NowPlayingMaxChars = 128  # tem que bater com o stringNum da tag NowPlaying_Text (tools/add_nowplaying_page.py)
$IconPath = Join-Path $WorkDir "icon.png"
# ffmpeg bundlado com o instalador do app oficial da Positivo -- usado
# pra preparar (redimensionar + limitar fps) gifs escolhidos pelo menu
# "Trocar GIF...", mesma logica do tools/prepare_gif.py.
$FfmpegPath = Join-Path $env:LOCALAPPDATA "Packages\PositivoInformticaS.A.PositivoMinitela_6yhrh9dmgepzj\LocalState\Minitela\assets\ffmpeg.exe"
$GifSlotFps = 10

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- janela invisivel para capturar o atalho global (WM_HOTKEY) + link serial ---
Add-Type @"
using System;
using System.Collections.Generic;
using System.IO.Ports;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using System.Windows.Forms;

public class HotkeyForm : Form {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public event Action HotkeyPressed = delegate { };
    private const int WM_HOTKEY = 0x0312;

    public HotkeyForm() {
        this.ShowInTaskbar = false;
        this.FormBorderStyle = FormBorderStyle.FixedToolWindow;
        this.StartPosition = FormStartPosition.Manual;
        this.Location = new System.Drawing.Point(-2000, -2000);
        this.Size = new System.Drawing.Size(1, 1);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == 1) {
            HotkeyPressed();
        }
        base.WndProc(ref m);
    }

    protected override void OnFormClosing(FormClosingEventArgs e) {
        UnregisterHotKey(this.Handle, 1);
        base.OnFormClosing(e);
    }
}

// Minimal client for the Minitela serial protocol (frame: 0x41 0x48 ... 0x4D 0x49),
// kept open for the whole app lifetime instead of reconnecting per command.
public class MinitelaLink : IDisposable {
    private SerialPort _port;
    private readonly object _lock = new object();
    private static readonly byte[] FrameStart = { 0x41, 0x48 };
    private static readonly byte[] FrameEnd = { 0x4D, 0x49 };

    public MinitelaLink(string portName, int baud) {
        _port = new SerialPort(portName, baud, Parity.None, 8, StopBits.One);
        _port.ReadTimeout = 300;
        _port.Open();
        Thread.Sleep(300);
        DiscardSafe();
    }

    private void DiscardSafe() {
        try { _port.DiscardInBuffer(); } catch { }
    }

    private byte[] BuildFrame(ushort cmdType, byte[] content) {
        int dataLen = 2 + content.Length;
        var list = new List<byte>();
        list.AddRange(FrameStart);
        list.Add((byte)((dataLen >> 8) & 0xFF));
        list.Add((byte)(dataLen & 0xFF));
        list.Add((byte)((cmdType >> 8) & 0xFF));
        list.Add((byte)(cmdType & 0xFF));
        list.AddRange(content);
        list.Add(0); list.Add(0); // CRC disabled (matches SideCar's own writes)
        list.AddRange(FrameEnd);
        return list.ToArray();
    }

    // Sends a command and waits (up to timeoutMs) for a frame of type expectType.
    // Returns the response content, or null on timeout.
    public byte[] SendAndWait(ushort cmdType, byte[] content, ushort expectType, int timeoutMs) {
        lock (_lock) {
            DiscardSafe();
            var frame = BuildFrame(cmdType, content);
            _port.Write(frame, 0, frame.Length);
            Thread.Sleep(80);

            var buf = new List<byte>();
            var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
            while (DateTime.Now < deadline) {
                try {
                    int avail = _port.BytesToRead;
                    if (avail > 0) {
                        byte[] tmp = new byte[avail];
                        _port.Read(tmp, 0, avail);
                        buf.AddRange(tmp);
                    }
                } catch { }

                int idx = IndexOfSeq(buf, FrameStart);
                if (idx >= 0 && buf.Count - idx >= 8) {
                    int ctrl = (buf[idx + 2] << 8) | buf[idx + 3];
                    int dataLen = ctrl & 0x7FFF;
                    int contentLen = dataLen - 2;
                    int frameSize = 2 + 2 + 2 + contentLen + 2 + 2;
                    if (contentLen >= 0 && buf.Count - idx >= frameSize) {
                        int type = (buf[idx + 4] << 8) | buf[idx + 5];
                        byte[] respContent = new byte[contentLen];
                        buf.CopyTo(idx + 6, respContent, 0, contentLen);
                        buf.RemoveRange(0, idx + frameSize);
                        if (type == expectType) {
                            return respContent;
                        }
                        continue; // unexpected type, keep waiting
                    }
                }
                Thread.Sleep(10);
            }
            return null;
        }
    }

    private static int IndexOfSeq(List<byte> haystack, byte[] needle) {
        for (int i = 0; i + needle.Length <= haystack.Count; i++) {
            bool ok = true;
            for (int j = 0; j < needle.Length; j++) {
                if (haystack[i + j] != needle[j]) { ok = false; break; }
            }
            if (ok) return i;
        }
        return -1;
    }

    public bool Handshake() {
        return SendAndWait(0x0080, new byte[0], 0x00C0, 2000) != null;
    }

    public bool WriteNumRegister(ushort regId, uint value) {
        byte[] content = new byte[7];
        content[0] = 0x80; // functionCode=write-num(1000b) << 4 | (count-1)=0
        content[1] = (byte)(regId >> 8); content[2] = (byte)(regId & 0xFF);
        content[3] = (byte)((value >> 24) & 0xFF);
        content[4] = (byte)((value >> 16) & 0xFF);
        content[5] = (byte)((value >> 8) & 0xFF);
        content[6] = (byte)(value & 0xFF);
        return SendAndWait(0x0090, content, 0x00D0, 2000) != null;
    }

    public bool WriteNumRegisters(ushort[] regIds, uint[] values) {
        int n = regIds.Length;
        byte[] content = new byte[1 + n * 6];
        content[0] = (byte)(0x80 | ((n - 1) & 0x0F));
        for (int i = 0; i < n; i++) {
            content[1 + i * 6] = (byte)(regIds[i] >> 8);
            content[2 + i * 6] = (byte)(regIds[i] & 0xFF);
            uint v = values[i];
            content[3 + i * 6] = (byte)((v >> 24) & 0xFF);
            content[4 + i * 6] = (byte)((v >> 16) & 0xFF);
            content[5 + i * 6] = (byte)((v >> 8) & 0xFF);
            content[6 + i * 6] = (byte)(v & 0xFF);
        }
        return SendAndWait(0x0090, content, 0x00D0, 2000) != null;
    }

    public bool WriteStringRegister(ushort regId, byte[] data) {
        byte[] content = new byte[5 + data.Length];
        content[0] = 0xD0;
        content[1] = (byte)(regId >> 8); content[2] = (byte)(regId & 0xFF);
        content[3] = (byte)((data.Length >> 8) & 0xFF);
        content[4] = (byte)(data.Length & 0xFF);
        Array.Copy(data, 0, content, 5, data.Length);
        return SendAndWait(0x0090, content, 0x00D0, 2000) != null;
    }

    public bool TryReadNumRegister(ushort regId, out uint value) {
        value = 0;
        byte[] content = new byte[3];
        content[0] = 0xC0;
        content[1] = (byte)(regId >> 8); content[2] = (byte)(regId & 0xFF);
        byte[] resp = SendAndWait(0x0090, content, 0x00D0, 1000);
        if (resp == null || resp.Length < 7) return false;
        // resp[0] = header, then regId(2) + value(4)
        value = (uint)((resp[3] << 24) | (resp[4] << 16) | (resp[5] << 8) | resp[6]);
        return true;
    }

    // GetDownloadStatus (0x0085 -> 0x00C5). content[0] eh o status:
    // 0x10/0x11 = preparando/baixando firmware novo, 0x20 = modo normal
    // (AHMI), pronto pra trocar de pagina. Retorna -1 se nao respondeu.
    public int GetDownloadStatus() {
        byte[] resp = SendAndWait(0x0085, new byte[0], 0x00C5, 1500);
        if (resp == null || resp.Length < 1) return -1;
        return resp[0];
    }

    private static uint ReadU32BE(byte[] b, int offset) {
        return (uint)((b[offset] << 24) | (b[offset + 1] << 16) | (b[offset + 2] << 8) | b[offset + 3]);
    }

    private static void WriteU32BE(byte[] b, int offset, uint value) {
        b[offset] = (byte)((value >> 24) & 0xFF);
        b[offset + 1] = (byte)((value >> 16) & 0xFF);
        b[offset + 2] = (byte)((value >> 8) & 0xFF);
        b[offset + 3] = (byte)(value & 0xFF);
    }

    // Igual ao SendAndWait, mas so ESCUTA (nao escreve nada) -- usado pro
    // padrao "processing" (0xFFFFFFFF), onde o dispositivo responde de
    // novo mais tarde sem que a gente tenha reenviado o comando.
    private byte[] ReadFrame(ushort expectType, int timeoutMs) {
        lock (_lock) {
            var buf = new List<byte>();
            var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
            while (DateTime.Now < deadline) {
                try {
                    int avail = _port.BytesToRead;
                    if (avail > 0) {
                        byte[] tmp = new byte[avail];
                        _port.Read(tmp, 0, avail);
                        buf.AddRange(tmp);
                    }
                } catch { }

                int idx = IndexOfSeq(buf, FrameStart);
                if (idx >= 0 && buf.Count - idx >= 8) {
                    int ctrl = (buf[idx + 2] << 8) | buf[idx + 3];
                    int dataLen = ctrl & 0x7FFF;
                    int contentLen = dataLen - 2;
                    int frameSize = 2 + 2 + 2 + contentLen + 2 + 2;
                    if (contentLen >= 0 && buf.Count - idx >= frameSize) {
                        int type = (buf[idx + 4] << 8) | buf[idx + 5];
                        byte[] respContent = new byte[contentLen];
                        buf.CopyTo(idx + 6, respContent, 0, contentLen);
                        buf.RemoveRange(0, idx + frameSize);
                        if (type == expectType) return respContent;
                        continue;
                    }
                }
                Thread.Sleep(10);
            }
            return null;
        }
    }

    public bool SwitchState(byte value) {
        byte[] resp = SendAndWait(0x0071, new byte[] { value }, 0x00B1, 2000);
        return resp != null && resp.Length >= 4 && ReadU32BE(resp, 0) == 0;
    }

    public bool Reboot() {
        // O ack do reboot quase sempre "falha" (o dispositivo desconecta no
        // meio da espera) -- isso e esperado, o chamador deve ignorar o
        // retorno e so esperar/reconectar (ver docs/PROTOCOL.md).
        return SendAndWait(0x0070, new byte[0], 0x00B0, 2000) != null;
    }

    private bool RequestDownload(uint addr, uint fileSize, byte[] fileId, out uint maxPageSize) {
        maxPageSize = 0;
        byte[] content = new byte[24];
        WriteU32BE(content, 0, addr);
        WriteU32BE(content, 4, fileSize);
        Array.Copy(fileId, 0, content, 8, 16);
        byte[] resp = SendAndWait(0x0081, content, 0x00C1, 60000);
        if (resp == null || resp.Length < 8) return false;
        maxPageSize = ReadU32BE(resp, 0);
        uint code = ReadU32BE(resp, 4);
        if (code == 0) return true;
        if (code != 0xFFFFFFFF) return false; // codigo de erro do dispositivo
        // "processing": espera uma resposta seguinte com code == 0
        var deadline = DateTime.Now.AddSeconds(30);
        while (DateTime.Now < deadline) {
            byte[] r2 = ReadFrame(0x00C1, 2000);
            if (r2 == null || r2.Length < 8) continue;
            uint c2 = ReadU32BE(r2, 4);
            if (c2 == 0) { maxPageSize = ReadU32BE(r2, 0); return true; }
            if (c2 != 0xFFFFFFFF) return false;
        }
        return false;
    }

    private bool SendChunk(uint offset, byte[] chunk, int timeoutMs) {
        int padding = (4 - (chunk.Length & 3)) & 3;
        byte[] content = new byte[4 + chunk.Length + padding];
        WriteU32BE(content, 0, offset);
        Array.Copy(chunk, 0, content, 4, chunk.Length);

        for (int attempt = 0; attempt < 3; attempt++) {
            byte[] resp = SendAndWait(0x0082, content, 0x00C2, timeoutMs);
            if (resp == null || resp.Length < 4) continue;
            uint code = ReadU32BE(resp, 0);
            if (code == 0) return true;
            if (code == 0xFFFFFFFF) {
                byte[] resp2 = ReadFrame(0x00C2, timeoutMs);
                if (resp2 != null && resp2.Length >= 4 && ReadU32BE(resp2, 0) == 0) return true;
                continue;
            }
            // codigo de erro -- tenta de novo
        }
        return false;
    }

    private bool DownloadComplete(int timeoutMs) {
        byte[] resp = SendAndWait(0x008F, new byte[0], 0x00CF, timeoutMs);
        if (resp == null || resp.Length < 4) return false;
        uint code = ReadU32BE(resp, 0);
        if (code == 0) return true;
        if (code != 0xFFFFFFFF) return false;
        var deadline = DateTime.Now.AddSeconds(10);
        while (DateTime.Now < deadline) {
            byte[] r2 = ReadFrame(0x00CF, 1000);
            if (r2 == null || r2.Length < 4) continue;
            uint c2 = ReadU32BE(r2, 0);
            if (c2 == 0) return true;
            if (c2 != 0xFFFFFFFF) return false;
        }
        return false;
    }

    // Sobe um arquivo de textura (.acf) inteiro pro endereco de memoria da
    // textura (0x08100000) -- reimplementacao do fluxo do UploadFile do
    // SideCar (core/upload.go), direto aqui, pra nao depender mais de rodar
    // um .exe de terceiros (sidecar-fixed.exe), que o Smart App Control da
    // Positivo passou a bloquear (nao assinado). onProgress recebe 0-100.
    public bool UploadTexture(byte[] data, Action<int> onProgress) {
        const uint textureAddr = 0x08100000;
        uint fileSize = (uint)data.Length;
        byte[] fileId = MD5.Create().ComputeHash(data);

        if (!Handshake()) return false;

        int status = GetDownloadStatus();
        if (status == 0x20) {
            if (!SwitchState(0x10)) return false;
        } else if (status != 0x10 && status != 0x11) {
            return false; // estado invalido/sem resposta
        }

        uint maxPageSize;
        if (!RequestDownload(textureAddr, fileSize, fileId, out maxPageSize) || maxPageSize == 0) {
            return false;
        }

        uint offset = 0;
        int lastPct = -1;
        while (offset < fileSize) {
            uint end = Math.Min(offset + maxPageSize, fileSize);
            byte[] chunk = new byte[end - offset];
            Array.Copy(data, offset, chunk, 0, chunk.Length);
            if (!SendChunk(offset, chunk, 5000)) return false;
            offset = end;
            int pct = (int)(100L * offset / fileSize);
            if (onProgress != null && pct != lastPct) { lastPct = pct; onProgress(pct); }
        }

        DownloadComplete(5000); // erro aqui e ignorado, igual ao SideCar original
        return true;
    }

    public void Dispose() {
        try { _port.Close(); } catch { }
    }
}

// Sem isso, o Windows credita o icone da bandeja/notificacoes ao processo
// hospedeiro (powershell.exe) em vez do nosso app -- por isso ele nao
// aparecia com o nome "Minitela" em Config. > Personalizacao > Barra de
// Tarefas > Outros icones da bandeja (aparecia como "Windows PowerShell").
public class AppIdentity {
    [DllImport("shell32.dll")]
    public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
}
"@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

[void][AppIdentity]::SetCurrentProcessExplicitAppUserModelID("MinitelaToolkit.TrayApp")

# --- "tocando agora" via WinRT (GSMTC) ---
# Add-Type/csc nao consegue referenciar .winmd diretamente (erro 0x80131047),
# entao isso usa a sintaxe nativa do PowerShell 5.1 pra tipos WinRT
# ([Tipo,Assembly,ContentType=WindowsRuntime]) em vez de C# embutido.
# Funciona igual pro Spotify e pra abas do YouTube no Vivaldi (qualquer
# app que registre uma sessao de midia do sistema).
#
# A chamada WinRT roda numa runspace em segundo plano, NUNCA na thread da
# interface -- a primeira ativacao COM/WinRT pode demorar mais que os 3s
# do timeout em alguns momentos, e isso travava o app inteiro (menu e
# atalho parando de responder) quando rodava a cada tick do timer de
# metricas. O app so LE um cache atualizado pela runspace, nunca espera.
$Global:NowPlayingCache = [hashtable]::Synchronized(@{ Text = "" })

$nowPlayingRunspace = [runspacefactory]::CreateRunspace()
$nowPlayingRunspace.ApartmentState = "STA"
$nowPlayingRunspace.Open()
$nowPlayingRunspace.SessionStateProxy.SetVariable("Cache", $Global:NowPlayingCache)
$nowPlayingRunspace.SessionStateProxy.SetVariable("MaxChars", $NowPlayingMaxChars)

$Global:nowPlayingPS = [powershell]::Create()
$Global:nowPlayingPS.Runspace = $nowPlayingRunspace
[void]$Global:nowPlayingPS.AddScript({
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    function Wait-WinRTTask {
        param($WinRtTask, [type]$ResultType)
        $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0].MakeGenericMethod($ResultType)
        $netTask = $asTaskGeneric.Invoke($null, @($WinRtTask))
        $netTask.Wait(5000) | Out-Null
        return $netTask.Result
    }
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime] | Out-Null

    while ($true) {
        try {
            $mgrTask = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
            $mgr = Wait-WinRTTask $mgrTask ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
            $session = $mgr.GetCurrentSession()
            if (-not $session) {
                $Cache.Text = ""
            } else {
                $propsTask = $session.TryGetMediaPropertiesAsync()
                $props = Wait-WinRTTask $propsTask ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                $artist = $props.Artist
                $title = $props.Title
                $text = if ($artist) { "$artist - $title" } else { $title }
                if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) }
                $Cache.Text = $text
            }
        } catch {
            # deixa o valor anterior no cache -- nao apaga por uma falha pontual
        }
        Start-Sleep -Seconds 4
    }
})
$Global:nowPlayingHandle = $Global:nowPlayingPS.BeginInvoke()

function Get-NowPlayingText {
    return $Global:NowPlayingCache.Text
}

# --- conexao serial (unica, mantida aberta pelo app inteiro) ---
$Global:link = New-Object MinitelaLink($Device, 115200)
[void]$Global:link.Handshake()
$Global:Busy = $false

# slots de GIF customizavel: nome do arquivo dentro de Zip\file.zip + pagina do dispositivo
$GifSlots = @(
    @{ File = "1i1h1e37393671471.gif"; ScreenIdx = 0 },
    @{ File = "1h1k1e37393671464.gif"; ScreenIdx = 1 },
    @{ File = "1h1m1e37393671466.gif"; ScreenIdx = 2 }
)

# --- estado ---
$Screens = @(
    @{ Name = "GIF 1";                            Page = 5 },
    @{ Name = "GIF 2";                            Page = 6 },
    @{ Name = "GIF 3";                            Page = 7 },
    @{ Name = "M$([char]0x00E9)tricas";           Page = 3 },
    @{ Name = "Tocando Agora";                    Page = 4 }
)
$Global:CurIdx = 0

function Set-Screen {
    param([int]$Idx)
    if ($Global:Busy) { return }
    $Global:CurIdx = $Idx
    $screen = $Screens[$Idx]
    [void]$Global:link.WriteNumRegister(2, [uint32]$screen.Page)
    $notifyIcon.Text = "Minitela: $($screen.Name)"
    foreach ($item in $menuItems.Keys) {
        $menuItems[$item].Checked = ($item -eq $Idx)
    }
}

function Get-CPUPercent {
    try {
        return [int](Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty LoadPercentage)
    } catch { return 0 }
}

function Get-RAMPercent {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $used = $os.TotalVisibleMemorySize - $os.FreePhysicalMemory
        return [int](100 * $used / $os.TotalVisibleMemorySize)
    } catch { return 0 }
}

function Get-BatteryInfo {
    try {
        $b = Get-CimInstance Win32_Battery | Select-Object -First 1
        if ($b) { return [int]$b.EstimatedChargeRemaining }
    } catch {}
    return 100
}

function Update-Metrics {
    # heartbeat pro watchdog.ps1: prova que o timer (e portanto o loop de
    # mensagens da UI) ainda esta rodando. Durante uma troca de gif a thread
    # de UI fica ocupada rodando Invoke-GifSwap ate o fim, entao esse timer
    # simplesmente nao dispara nesse periodo -- por isso o watchdog tambem
    # respeita um arquivo de lock separado (ver Invoke-GifSwap) em vez de
    # confiar so na idade do heartbeat.
    try { Set-Content -Path (Join-Path $WorkDir "heartbeat.txt") -Value (Get-Date -Format o) -Force } catch {}

    if ($Global:Busy) { return }
    $cpu = Get-CPUPercent
    $ram = Get-RAMPercent
    $bat = Get-BatteryInfo

    [void]$Global:link.WriteStringRegister(1500, [System.Text.Encoding]::ASCII.GetBytes("CPU $cpu%"))
    [void]$Global:link.WriteStringRegister(1501, [System.Text.Encoding]::ASCII.GetBytes("RAM $ram%"))
    [void]$Global:link.WriteStringRegister(1502, [System.Text.Encoding]::ASCII.GetBytes("Bateria $bat%"))

    $nowPlaying = Get-NowPlayingText
    if ($nowPlaying) {
        [void]$Global:link.WriteStringRegister(1503, [System.Text.Encoding]::UTF8.GetBytes($nowPlaying))
    }
}

# --- troca de GIF pelo menu (le arquivo -> regenera ACF -> upload -> reboot) ---

function Get-GifDimensions {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 10 -or $Bytes[0] -ne 0x47 -or $Bytes[1] -ne 0x49 -or $Bytes[2] -ne 0x46) {
        return $null
    }
    $w = [int]$Bytes[6] -bor ([int]$Bytes[7] -shl 8)
    $h = [int]$Bytes[8] -bor ([int]$Bytes[9] -shl 8)
    return @{ Width = $w; Height = $h }
}

function Invoke-PrepareGif {
    param([string]$InputPath, [string]$OutputPath, [int]$Width, [int]$Height, [int]$Fps)

    if (-not (Test-Path $FfmpegPath)) { return $false }

    # mesma logica do tools/prepare_gif.py: paleta unica compartilhada
    # entre todos os quadros (evita flicker de cor), scale+crop sem
    # distorcer (preenche o quadro, recorta o excesso).
    $baseVf = "fps=$Fps,scale=${Width}:${Height}:force_original_aspect_ratio=increase,crop=${Width}:${Height}"
    $palette = "$OutputPath.palette.png"

    $p1 = Start-Process -FilePath $FfmpegPath -ArgumentList @("-y", "-i", $InputPath, "-vf", "$baseVf,palettegen", $palette) -NoNewWindow -Wait -PassThru
    if ($p1.ExitCode -ne 0 -or -not (Test-Path $palette) -or (Get-Item $palette).Length -eq 0) {
        Remove-Item $palette -ErrorAction SilentlyContinue
        return $false
    }

    $p2 = Start-Process -FilePath $FfmpegPath -ArgumentList @("-y", "-i", $InputPath, "-i", $palette, "-lavfi", "$baseVf[x];[x][1:v]paletteuse", $OutputPath) -NoNewWindow -Wait -PassThru
    Remove-Item $palette -ErrorAction SilentlyContinue

    return ($p2.ExitCode -eq 0 -and (Test-Path $OutputPath))
}

function Set-ZipEntryBytes {
    param([string]$ZipPath, [string]$EntryName, [byte[]]$NewBytes)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $archive.GetEntry($EntryName)
        if ($entry) { $entry.Delete() }
        $newEntry = $archive.CreateEntry($EntryName)
        $stream = $newEntry.Open()
        try { $stream.Write($NewBytes, 0, $NewBytes.Length) }
        finally { $stream.Close() }
    } finally {
        $archive.Dispose()
    }
}

function Invoke-AcfGenerator {
    $genDir = Join-Path $WorkDir "Gen"
    $jsonDir = Join-Path $genDir "json"
    if (Test-Path $jsonDir) {
        Get-ChildItem $jsonDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    # o gerador nao cria a pasta de saida -- falha silenciosamente ("File
    # created error") se ela nao existir de antemao.
    New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir "ACF") | Out-Null

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $genDir "AHMISimGenDemo_og.exe"
    $psi.Arguments = '-f "..\Zip\file.zip" -m 2 -c 0 -e 0 -d 1 -o "..\ACF"'
    $psi.WorkingDirectory = $genDir
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 500
    $proc.StandardInput.WriteLine("13")
    $proc.StandardInput.Close()
    [void]$proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit(60000)
    return ($proc.ExitCode -eq 0)
}

# Sobe o ACF gerado e reinicia o dispositivo, tudo via MinitelaLink (C#
# embutido) -- nao depende mais de rodar o sidecar-fixed.exe como processo
# separado. Isso passou a ser necessario depois que o Smart App Control do
# Windows comecou a bloquear esse .exe (nao assinado); reimplementamos o
# protocolo de upload (RequestDownload/DownloadData/DownloadComplete) igual
# ao core/upload.go do SideCar, so que direto no MinitelaLink existente.
$MaxUploadBytes = 6436 * 1024  # mesmo teto do SideCar (core/upload.go, maxUploadFileSize)

function Invoke-UploadAndReboot {
    param([MinitelaLink]$Link)
    $acf = Join-Path $WorkDir "ACF\Texture.acf"
    $acfBytes = [System.IO.File]::ReadAllBytes($acf)
    if ($acfBytes.Length -gt $MaxUploadBytes) {
        throw "ACF tem $([math]::Round($acfBytes.Length / 1KB)) KB, acima do limite de $([math]::Round($MaxUploadBytes / 1KB)) KB -- escolha um gif menor ou com menos quadros."
    }
    $uploadOk = $Link.UploadTexture($acfBytes, $null)
    # o reboot sempre "falha" com um erro cosmetico (o dispositivo desconecta no meio da espera pela resposta) - ignorado de proposito
    [void]$Link.Reboot()
    return $uploadOk
}

# Troca de pagina logo apos um reboot: o dispositivo aceita a escrita do
# registrador 2 sem erro, mas ainda pode estar carregando a pagina padrao
# por baixo (ver gotcha em docs/PROTOCOL.md) -- por isso confirma lendo o
# registrador de volta, repetindo ate bater com o valor esperado.
function Set-ScreenWithRetry {
    param([MinitelaLink]$Link, [int]$Target, [int]$MaxTries = 10)
    for ($i = 0; $i -lt $MaxTries; $i++) {
        [void]$Link.WriteNumRegister(2, [uint32]$Target)
        Start-Sleep -Milliseconds 800
        $val = 0
        if ($Link.TryReadNumRegister(2, [ref]$val) -and [int]$val -eq $Target) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Connect-Minitela {
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $l = New-Object MinitelaLink($Device, 115200)
            if ($l.Handshake()) { return $l }
            $l.Dispose()
        } catch {}
        Start-Sleep -Seconds 2
    }
    return $null
}

function Invoke-GifSwap {
    param([int]$SlotIdx)
    if ($Global:Busy) { return }

    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "GIF (*.gif)|*.gif"
    $dlg.Title = "Escolher GIF para o slot $($SlotIdx + 1)"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $rawBytes = [System.IO.File]::ReadAllBytes($dlg.FileName)
    if (-not (Get-GifDimensions -Bytes $rawBytes)) {
        $notifyIcon.ShowBalloonTip(5000, "Minitela", "Isso n$([char]0x00E3)o parece ser um GIF v$([char]0x00E1)lido.", [System.Windows.Forms.ToolTipIcon]::Error)
        return
    }

    $Global:Busy = $true
    $metricsTimer.Stop()
    $notifyIcon.ShowBalloonTip(4000, "Minitela", "Trocando GIF $($SlotIdx + 1)... isso pode levar varios minutos agora (upload direto pela porta serial, sem o sidecar-fixed.exe) -- n$([char]0x00E3)o feche o app.", [System.Windows.Forms.ToolTipIcon]::Info)

    # avisa o watchdog.ps1 que uma operacao longa e legitima esta rolando,
    # pra ele nao confundir isso com o app travado e reiniciar no meio de
    # um upload/reboot do dispositivo.
    $lockPath = Join-Path $WorkDir "gifswap.lock"
    Set-Content -Path $lockPath -Value (Get-Date -Format o) -Force

    try {
        # prepara automaticamente: redimensiona pro 192x192 do slot (sem
        # distorcer) e limita a taxa de quadros -- mesma logica do
        # tools/prepare_gif.py, so que chamada direto daqui.
        $preparedPath = Join-Path $WorkDir "gif_prepared_tmp.gif"
        if (Invoke-PrepareGif -InputPath $dlg.FileName -OutputPath $preparedPath -Width 192 -Height 192 -Fps $GifSlotFps) {
            $bytes = [System.IO.File]::ReadAllBytes($preparedPath)
            Remove-Item $preparedPath -ErrorAction SilentlyContinue
        } else {
            # ffmpeg falhou ou nao foi encontrado -- usa o arquivo original
            # sem redimensionar/limitar fps (comportamento antigo).
            $bytes = $rawBytes
        }

        $zipPath = Join-Path $WorkDir "Zip\file.zip"
        Set-ZipEntryBytes -ZipPath $zipPath -EntryName $GifSlots[$SlotIdx].File -NewBytes $bytes

        if (-not (Invoke-AcfGenerator)) {
            throw "falha ao gerar o ACF (AHMISimGenDemo_og.exe)"
        }

        if (-not (Invoke-UploadAndReboot -Link $Global:link)) {
            throw "falha ao subir a textura pro dispositivo"
        }
        $Global:link.Dispose()
        Start-Sleep -Seconds 15

        $newLink = Connect-Minitela
        if (-not $newLink) {
            throw "n$([char]0x00E3)o reconectei ao dispositivo depois do reboot"
        }
        $target = [int]$Screens[$GifSlots[$SlotIdx].ScreenIdx].Page
        $pageOk = Set-ScreenWithRetry -Link $newLink -Target $target
        $Global:link = $newLink
        $metricsTimer.Start()
        $Global:CurIdx = $GifSlots[$SlotIdx].ScreenIdx
        foreach ($item in $menuItems.Keys) {
            $menuItems[$item].Checked = ($item -eq $Global:CurIdx)
        }

        if ($pageOk) {
            $notifyIcon.ShowBalloonTip(4000, "Minitela", "GIF $($SlotIdx + 1) atualizado!", [System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            $notifyIcon.ShowBalloonTip(8000, "Minitela", "GIF $($SlotIdx + 1) atualizado, mas o dispositivo nao confirmou a troca de tela -- aperte a tecla MINITELA.", [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    } catch {
        $notifyIcon.ShowBalloonTip(8000, "Minitela", "Erro ao trocar o GIF: $_", [System.Windows.Forms.ToolTipIcon]::Error)
        if (-not $Global:link) {
            $Global:link = Connect-Minitela
        }
        $metricsTimer.Start()
    } finally {
        $Global:Busy = $false
        Remove-Item $lockPath -ErrorAction SilentlyContinue
    }
}

# --- icone na bandeja ---
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
if (Test-Path $IconPath) {
    # Icon(path) only accepts .ico; load via Bitmap->HICON so .png/.jpg work too.
    $bmp = New-Object System.Drawing.Bitmap($IconPath)
    $notifyIcon.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
} else {
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$notifyIcon.Visible = $true
$notifyIcon.Text = "Minitela"

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuItems = @{}
for ($i = 0; $i -lt $Screens.Count; $i++) {
    $idx = $i
    $item = $contextMenu.Items.Add($Screens[$i].Name)
    $item.add_Click({ Set-Screen $idx }.GetNewClosure())
    $menuItems[$idx] = $item
}
$contextMenu.Items.Add("-") | Out-Null
for ($i = 0; $i -lt $GifSlots.Count; $i++) {
    $slotIdx = $i
    $swapItem = $contextMenu.Items.Add("Trocar GIF $($i + 1)...")
    $swapItem.add_Click({ Invoke-GifSwap $slotIdx }.GetNewClosure())
}
$contextMenu.Items.Add("-") | Out-Null
$exitItem = $contextMenu.Items.Add("Sair")
$exitItem.add_Click({
    # avisa o watchdog.ps1 que essa saida foi intencional (clique em
    # "Sair"), pra ele nao reiniciar o app / se desligar tambem em vez de
    # tratar isso como uma queda.
    try { Set-Content -Path (Join-Path $WorkDir "stop_requested.flag") -Value (Get-Date -Format o) -Force } catch {}
    $notifyIcon.Visible = $false
    $metricsTimer.Stop()
    $Global:link.Dispose()
    try { $Global:nowPlayingPS.Stop(); $Global:nowPlayingPS.Dispose() } catch {}
    $hotkeyForm.Close()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $contextMenu

# --- janela do atalho global ---
$hotkeyForm = New-Object HotkeyForm
[void]$hotkeyForm.Handle   # forca a criacao do HWND sem chamar Show()
$hotkeyForm.add_HotkeyPressed({
    Set-Screen ((($Global:CurIdx) + 1) % $Screens.Count)
})

# tecla dedicada "MINITELA" do teclado do R15M -- identificada via hook de
# baixo nivel (nao aparece documentada em lugar nenhum): manda VK_F16
# (0x7F), sem nenhum modificador. MOD_NOREPEAT evita disparar WM_HOTKEY
# varias vezes se ela ficar segurando a tecla.
$MOD_NOREPEAT = 0x4000
$VK_F16 = 0x7F
$hotkeyOk = [HotkeyForm]::RegisterHotKey($hotkeyForm.Handle, 1, $MOD_NOREPEAT, $VK_F16)
if (-not $hotkeyOk) {
    $notifyIcon.ShowBalloonTip(5000, "Minitela", "N$([char]0x00E3)o consegui registrar a tecla MINITELA (provavelmente j$([char]0x00E1) est$([char]0x00E1) em uso por outro programa). Use o menu do $([char]0x00ED)cone na bandeja.", [System.Windows.Forms.ToolTipIcon]::Warning)
}

# --- timer de metricas (a cada 5s) ---
$metricsTimer = New-Object System.Windows.Forms.Timer
$metricsTimer.Interval = 5000
$metricsTimer.add_Tick({ Update-Metrics })
$metricsTimer.Start()

# estado inicial
Update-Metrics
Set-Screen 0

[System.Windows.Forms.Application]::Run()
