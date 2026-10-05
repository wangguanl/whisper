#Requires -Version 5.0
<#
.SYNOPSIS
    启动 openai-whisper 本地转录（wanggang-run-oss）。
.DESCRIPTION
    无参运行后交互选择模型；再输入音频路径（默认 tests\jfk.flac）。
.PARAMETER Mode
    direct = 本机直接运行；docker = 未提供官方 compose，会提示不可用。
.PARAMETER Port
    本项目为 CLI，忽略端口。
.PARAMETER Service
    内部用：跳过菜单，直接用指定模型 Id（tiny/turbo/medium/large）。
#>
[CmdletBinding()]
param(
    [ValidateSet('direct', 'docker')]
    [string]$Mode = 'direct',

    [int]$Port = 0,

    [string]$Service = ''
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw '未找到 PowerShell 7 (pwsh)。请先全局安装：winget install --id Microsoft.PowerShell -e'
    }
    $argList = @('-NoProfile', '-File', $PSCommandPath)
    foreach ($key in $PSBoundParameters.Keys) {
        $argList += "-$key"
        $val = $PSBoundParameters[$key]
        if ($val -isnot [System.Management.Automation.SwitchParameter]) {
            $argList += [string]$val
        }
    }
    & $pwsh.Source @argList
    exit $LASTEXITCODE
}

Set-Location $PSScriptRoot

$FfmpegBin = 'E:\Programs\ffmpeg-master-latest-win64-gpl\bin'
if (Test-Path $FfmpegBin) {
    $env:Path = "$FfmpegBin;$env:Path"
} else {
    Write-Warning "未找到本机 ffmpeg：$FfmpegBin"
}

function Show-GpuStatus {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        Write-Warning '未检测到 nvidia-smi，跳过 GPU 检查。'
        return
    }
    Write-Host '=== GPU 状态 ===' -ForegroundColor Cyan
    & nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu --format=csv
}

function Test-PortBusy {
    param([int]$TargetPort)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $TargetPort)
        $listener.Start()
        return $false
    } catch {
        return $true
    } finally {
        if ($null -ne $listener) { $listener.Stop() }
    }
}

function Get-FreePort {
    param(
        [int]$StartPort,
        [int]$MaxTries = 50
    )
    if ($StartPort -lt 1) { $StartPort = 1024 }
    $end = $StartPort + $MaxTries - 1
    if ($end -gt 65535) { $end = 65535 }
    $p = $StartPort
    while ($p -le $end) {
        if (-not (Test-PortBusy -TargetPort $p)) {
            if ($p -ne $StartPort) {
                Write-Host "端口 $StartPort 已占用，顺延到 $p" -ForegroundColor Yellow
            }
            return $p
        }
        $p++
    }
    throw "从 $StartPort 起连续探测均被占用，放弃。"
}

function Select-ServicesInteractive {
    param([object[]]$AllServices)

    if ($AllServices.Count -eq 0) {
        throw '未配置 $Services，请按项目改写模板。'
    }
    if ($AllServices.Count -eq 1) {
        Write-Host "仅一个服务，直接启动：$($AllServices[0].Label)" -ForegroundColor Cyan
        return @($AllServices[0])
    }

    Write-Host ''
    Write-Host '=== 用哪个模型转录？===' -ForegroundColor Cyan
    for ($i = 0; $i -lt $AllServices.Count; $i++) {
        $svc = $AllServices[$i]
        $portHint = if ($svc.NeedsPort) { "端口起点 $($svc.PreferredPort)" } else { $svc.VramHint }
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $svc.Label, $portHint)
    }
    Write-Host ("  [{0}] 全部开" -f ($AllServices.Count + 1))
    Write-Host '  [0] 取消'
    Write-Host ''

    $defaultChoice = '1'
    $raw = Read-Host "请选择（可多选，逗号分隔，如 1,2；默认 $defaultChoice）"
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $defaultChoice }

    if ($raw.Trim() -eq '0') {
        throw '已取消启动。'
    }

    $allIndex = $AllServices.Count + 1
    $parts = $raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $selected = [System.Collections.Generic.List[object]]::new()

    foreach ($part in $parts) {
        $n = 0
        if (-not [int]::TryParse($part, [ref]$n)) {
            throw "无效选项：$part"
        }
        if ($n -eq $allIndex) {
            return @($AllServices)
        }
        if ($n -lt 1 -or $n -gt $AllServices.Count) {
            throw "选项超出范围：$n"
        }
        $selected.Add($AllServices[$n - 1])
    }

    if ($selected.Count -eq 0) {
        throw '未选择任何服务。'
    }

    $byId = [ordered]@{}
    foreach ($s in $selected) { $byId[$s.Id] = $s }
    return @($byId.Values)
}

function Assert-GpuOkForSelection {
    param([object[]]$Selected)

    $gpuServices = @($Selected | Where-Object { $_.UsesGpu })
    if ($gpuServices.Count -le 1) { return }

    $labels = ($gpuServices | ForEach-Object { $_.Label }) -join ', '
    Write-Host ''
    Write-Host "已选多个占卡模型：$labels" -ForegroundColor Yellow
    Write-Host '16GB 显存下同时加载多个 Whisper 模型容易 OOM。请确认剩余显存足够，或改回只开一个。' -ForegroundColor Yellow
    $confirm = Read-Host '仍要继续？[y/N]'
    if ($confirm -notmatch '^[yY]') {
        throw '已取消：多服务占卡未确认。'
    }
}

function Get-AudioPath {
    $defaultAudio = Join-Path $PSScriptRoot 'tests\jfk.flac'
    $raw = Read-Host "音频路径（回车默认 $defaultAudio）"
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $defaultAudio }
    if (-not (Test-Path -LiteralPath $raw)) {
        throw "找不到音频文件：$raw"
    }
    return (Resolve-Path -LiteralPath $raw).Path
}

# --- Whisper：按模型尺寸选择 ---
$Services = @(
    [pscustomobject]@{
        Id            = 'turbo'
        Label         = 'turbo（默认，快，~6GB）'
        PreferredPort = 0
        NeedsPort     = $false
        UsesGpu       = $true
        VramHint      = '~6GB VRAM'
        ModelName     = 'turbo'
    }
    [pscustomobject]@{
        Id            = 'tiny'
        Label         = 'tiny（快速验证，~1GB）'
        PreferredPort = 0
        NeedsPort     = $false
        UsesGpu       = $true
        VramHint      = '~1GB VRAM'
        ModelName     = 'tiny'
    }
    [pscustomobject]@{
        Id            = 'medium'
        Label         = 'medium（可翻译，~5GB）'
        PreferredPort = 0
        NeedsPort     = $false
        UsesGpu       = $true
        VramHint      = '~5GB VRAM'
        ModelName     = 'medium'
    }
    [pscustomobject]@{
        Id            = 'large'
        Label         = 'large（最高质量，~10GB）'
        PreferredPort = 0
        NeedsPort     = $false
        UsesGpu       = $true
        VramHint      = '~10GB VRAM'
        ModelName     = 'large'
    }
)

function Start-ProjectService {
    param(
        [Parameter(Mandatory)]
        [object]$Service,

        [Parameter(Mandatory)]
        [string]$RunMode,

        [int]$ListenPort = 0
    )

    if ($RunMode -eq 'docker') {
        throw '本仓库无官方 docker-compose 启动路径；请用 -Mode direct。'
    }

    $venvPython = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        throw "未找到 $venvPython。请先按 docs\RUN.md 创建 venv 并 uv pip install -e ."
    }

    $audio = Get-AudioPath
    $model = $Service.ModelName
    Write-Host "转录：$audio  model=$model  device=cuda" -ForegroundColor Cyan

    # 不用 whisper.exe（uv trampoline 迁路径后失败），也不直接 -m whisper（editable 元路径易变成 unknown location）。
    # 将仓库根插入 sys.path 再调 cli。
    & $venvPython -c "import sys; sys.path.insert(0, r'$PSScriptRoot'); from whisper.transcribe import cli; sys.argv=['whisper']+sys.argv[1:]; raise SystemExit(cli() or 0)" `
        $audio --model $model --device cuda
    if ($LASTEXITCODE -ne 0) {
        throw "whisper 退出码 $LASTEXITCODE"
    }
}

Show-GpuStatus

if ($Service) {
    $match = @($Services | Where-Object { $_.Id -eq $Service })
    if ($match.Count -eq 0) {
        throw "未知服务 Id：$Service。可选：$($Services.Id -join ', ')"
    }
    $chosen = $match
} else {
    $chosen = Select-ServicesInteractive -AllServices $Services
    Assert-GpuOkForSelection -Selected $chosen
}

$multi = $chosen.Count -gt 1

if ($multi) {
    $started = @()
    foreach ($svc in $chosen) {
        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.AddRange([string[]]@('-NoProfile', '-File', $PSCommandPath, '-Mode', $Mode, '-Service', $svc.Id))

        $p = Start-Process -FilePath 'pwsh' -ArgumentList $argList -PassThru -WorkingDirectory $PSScriptRoot
        $started += [pscustomobject]@{ Id = $svc.Id; Label = $svc.Label; Port = 0; Pid = $p.Id }
        Write-Host "已后台启动 $($svc.Label) PID=$($p.Id)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '=== 已启动 ===' -ForegroundColor Cyan
    foreach ($s in $started) {
        Write-Host ("- {0} pid={1}" -f $s.Label, $s.Pid)
    }
    Write-Host '各任务在独立进程中运行；结束请自行停对应 PID。' -ForegroundColor Yellow
    return
}

$svc = $chosen[0]
Start-ProjectService -Service $svc -RunMode $Mode -ListenPort 0