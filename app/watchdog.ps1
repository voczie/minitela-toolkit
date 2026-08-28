# Watchdog do Minitela: inicia o app e fica de olho nele, reiniciando
# sozinho se ele cair ou travar (nao responder mais / parar de atualizar
# o heartbeat). Roda pra sempre em segundo plano -- e ele, nao o
# minitela.ps1 direto, que deve ser colocado na Inicializacao do Windows.
#
# Como detecta travamento:
#   - o processo simplesmente nao existe mais -> reinicia (caiu)
#   - o processo existe mas Responding=$false (nao processa mensagens da
#     UI) -> reinicia
#   - o processo existe e Responding=$true, mas faz tempo demais que o
#     heartbeat.txt nao e atualizado (o minitela.ps1 escreve nele a cada
#     tick do timer de metricas, a cada 5s) -> reinicia
#   Excecao: se gifswap.lock existir e for recente, uma troca de gif
#   esta rolando de verdade (pode levar ~30-90s, incluindo reboot do
#   dispositivo) -- nao mexe nesse caso, so espera.

$WorkDir = Join-Path $env:USERPROFILE "ahmi-work"
$ScriptPath = Join-Path $WorkDir "minitela.ps1"
$HeartbeatPath = Join-Path $WorkDir "heartbeat.txt"
$LockPath = Join-Path $WorkDir "gifswap.lock"
$StopFlagPath = Join-Path $WorkDir "stop_requested.flag"
$LogPath = Join-Path $WorkDir "watchdog.log"

$CheckIntervalSeconds = 20
$MaxHeartbeatAgeSeconds = 60     # sem lock ativo, o heartbeat devia atualizar a cada 5s
$MaxLockAgeSeconds = 300         # trava-o de gif nunca deveria levar mais que isso -- se levar, presume travado/orfao
$StartupGraceSeconds = 20        # tempo que o app tem pra escrever o primeiro heartbeat antes de comecar a checar

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    try { Add-Content -Path $LogPath -Value $line } catch {}
}

function Get-MinitelaProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*$([System.IO.Path]::GetFileName($ScriptPath))*" }
}

function Stop-Minitela {
    Get-MinitelaProcess | ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    # a interface .Responding do Win32_Process nao existe -- usa Get-Process
    # (por Id) soh pra garantir que realmente morreu.
    Start-Sleep -Seconds 2
}

function Start-Minitela {
    Remove-Item $HeartbeatPath -ErrorAction SilentlyContinue
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $ScriptPath
    ) -WindowStyle Hidden
    Write-Log "iniciado"
}

function Test-StopRequested {
    if (Test-Path $StopFlagPath) {
        Remove-Item $StopFlagPath -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

function Test-IsHung {
    # lock de troca de gif ativo e recente -> nao mexe, so espera
    if (Test-Path $LockPath) {
        $lockAge = ((Get-Date) - (Get-Item $LockPath).LastWriteTime).TotalSeconds
        if ($lockAge -lt $MaxLockAgeSeconds) {
            return $false
        }
        Write-Log "gifswap.lock com $([int]$lockAge)s -- ignorando, considerando travado mesmo assim"
    }

    $procs = @(Get-MinitelaProcess)
    if ($procs.Count -eq 0) {
        Write-Log "processo nao encontrado"
        return $true
    }

    # Responding vem do Get-Process (nao do Win32_Process/CIM)
    $anyResponding = $false
    foreach ($p in $procs) {
        try {
            $gp = Get-Process -Id $p.ProcessId -ErrorAction Stop
            if ($gp.Responding) { $anyResponding = $true }
        } catch {}
    }
    if (-not $anyResponding) {
        Write-Log "processo existe mas nao responde (Responding=false)"
        return $true
    }

    if (-not (Test-Path $HeartbeatPath)) {
        return $false  # ainda dentro da janela de carencia inicial, provavelmente
    }

    $age = ((Get-Date) - (Get-Item $HeartbeatPath).LastWriteTime).TotalSeconds
    if ($age -gt $MaxHeartbeatAgeSeconds) {
        Write-Log "heartbeat com $([int]$age)s de idade (limite $MaxHeartbeatAgeSeconds s)"
        return $true
    }

    return $false
}

Write-Log "watchdog iniciado"
Remove-Item $StopFlagPath -ErrorAction SilentlyContinue  # flag de uma sessao anterior nao deve valer agora
Start-Minitela
Start-Sleep -Seconds $StartupGraceSeconds

while ($true) {
    Start-Sleep -Seconds $CheckIntervalSeconds

    if (Test-StopRequested) {
        Write-Log "saida intencional (menu Sair) -- watchdog tambem encerrando"
        break
    }

    if (Test-IsHung) {
        Write-Log "reiniciando minitela.ps1"
        Stop-Minitela
        Start-Minitela
        Start-Sleep -Seconds $StartupGraceSeconds
    }
}
