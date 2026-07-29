[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RemoteIp,

    [Parameter(Mandatory = $true)]
    [string]$ExperimentName,

    [Parameter(Mandatory = $true)]
    [string[]]$Strats,

    [Parameter(Mandatory = $true)]
    [int[]]$PruningLayers,

    [Parameter(Mandatory = $true)]
    [int[]]$PruningRates,

    [ValidateRange(0, 1023)]
    [int]$FirstDevice = 0,
    [int[]]$DeviceIds = @(),
    [ValidateRange(1, 65535)]
    [int]$FirstPort = 8100,
    [string]$SshUser = "root",
    [Parameter(Mandatory = $true)]
    [System.Security.SecureString]$SshPassword,
    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,
    [string]$ContainerName = "vllm-tyc-v191rc1",
    [string]$ProjectRoot = "",
    [string]$ConfigPath = "",
    [string]$TestPath = "",
    [string]$PythonPath = "",
    [string]$OutputRoot = "",
    [ValidateRange(1, 65535)]
    [int]$UvicornPort = 8899,
    [ValidateRange(1, 128)]
    [int]$UvicornWorkers = 4,
    [ValidateRange(1, 4)]
    [int]$MaxConcurrency = 4,
    [ValidateRange(2, 1024)]
    [int]$TotalDevices = 8,
    [ValidateRange(1, 86400)]
    [int]$StartupTimeoutSeconds = 900,
    [ValidateRange(0, 604800)]
    [int]$TestTimeoutSeconds = 0,
    [switch]$KeepModifiedFiles,
    [switch]$KeepWorkspaces,
    [switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:SshPasswordEnabled = $false
$script:SshPasswordPlainText = $null
$script:SshAskPassPath = $null

function Write-Step([string]$Message) {
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Read-TextFile([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encoding = $null
    $preambleLength = 0

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.UTF8Encoding]::new($true, $true)
        $preambleLength = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
        $preambleLength = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true)
        $preambleLength = 2
    } else {
        $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
        try {
            $null = $utf8.GetString($bytes)
            $encoding = $utf8
        } catch [System.Text.DecoderFallbackException] {
            $encoding = [System.Text.Encoding]::Default
        }
    }

    $text = $encoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)
    return [pscustomobject]@{
        Text = $text
        Encoding = $encoding
    }
}

function Write-TextFile([string]$Path, [string]$Text, [System.Text.Encoding]$Encoding) {
    [System.IO.File]::WriteAllText($Path, $Text, $Encoding)
}

function Get-SafeIdPart([string]$Value) {
    $part = $Value -replace '[^A-Za-z0-9_.-]', '_'
    if ([string]::IsNullOrWhiteSpace($part)) {
        throw "超参数值 '$Value' 无法生成有效 ID。"
    }
    return $part
}

function Quote-Bash([string]$Value) {
    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $escapedQuote = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    return $singleQuote + $Value.Replace($singleQuote, $escapedQuote) + $singleQuote
}

function Find-ConfigFile([string]$Root) {
    $matches = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.py" |
        Where-Object {
            $_.FullName -notmatch '[\\/](?:\.venv|\.git|e2e_workspaces|__pycache__)[\\/]'
        } |
        Where-Object {
            try {
                $text = (Read-TextFile $_.FullName).Text
                $text -match 'LARGEMODEL32B_HOST\s*:' -and
                $text -match 'LARGEMODEL4B_PORT\s*:'
            } catch {
                $false
            }
        }
    if ($matches.Count -ne 1) {
        $names = ($matches.FullName -join ", ")
        throw "无法唯一定位配置文件（找到 $($matches.Count) 个）：$names。请使用 -ConfigPath 指定。"
    }
    return $matches[0].FullName
}

function Replace-Exactly(
    [string]$Text,
    [string]$Pattern,
    [string]$Replacement,
    [string]$Description
) {
    $found = [regex]::Matches($Text, $Pattern)
    if ($found.Count -ne 1) {
        throw "$Description 应匹配 1 次，实际匹配 $($found.Count) 次。"
    }
    return [regex]::Replace($Text, $Pattern, $Replacement)
}

function Set-LocalConfiguration(
    [string]$Path,
    [string]$Ip,
    [int]$BasePort,
    [string]$BaseModel,
    [string]$SftModel
) {
    $file = Read-TextFile $Path
    $text = $file.Text
    $text = Replace-Exactly $text '(?m)^(\s*LARGEMODEL32B_HOST\s*:\s*str\s*=\s*)["''][^"'']*["'']' ('${1}"' + $Ip + '"') "LARGEMODEL32B_HOST"
    $text = Replace-Exactly $text '(?m)^(\s*LARGEMODEL32B_PORT\s*:\s*int\s*=\s*)\d+' ('${1}' + $BasePort) "LARGEMODEL32B_PORT"
    $text = Replace-Exactly $text '(?m)^(\s*LARGEMODEL32B_MODEL\s*:\s*str\s*=\s*)["''][^"'']*["'']' ('${1}"' + $BaseModel + '"') "LARGEMODEL32B_MODEL"
    $text = Replace-Exactly $text '(?m)^(\s*LARGEMODEL4B_HOST\s*:\s*str\s*=\s*)["''][^"'']*["'']' ('${1}"' + $Ip + '"') "LARGEMODEL4B_HOST"
    $text = Replace-Exactly $text '(?m)^(\s*LARGEMODEL4B_PORT\s*:\s*int\s*=\s*)\d+' ('${1}' + ($BasePort + 1)) "LARGEMODEL4B_PORT"
    $text = Replace-Exactly $text '(?m)^(\s*LARGEMODEL4B_MODEL\s*:\s*str\s*=\s*)["''][^"'']*["'']' ('${1}"' + $SftModel + '"') "LARGEMODEL4B_MODEL"
    Write-TextFile $Path $text $file.Encoding
}

function Set-TestConfiguration([string]$Path, [string]$OutputPath, [int]$Port) {
    $file = Read-TextFile $Path
    $text = $file.Text
    $urlPattern = '(?m)^(\s*default_url_8890\s*=\s*)["''][^"'']*["''](\s*)$'
    $url = "http://127.0.0.1:$Port/v1/chat/completions"
    $text = Replace-Exactly $text $urlPattern ('${1}"' + $url + '"${2}') "default_url_8890"

    $outputPattern = '(?m)^(\s*output_file\s*=\s*)(?:r|rf|fr)?["''][^"'']*["''](\s*,\s*)$'
    $text = Replace-Exactly $text $outputPattern ('${1}r"' + $OutputPath + '"${2}') "output_file"
    Write-TextFile $Path $text $file.Encoding
}

function Initialize-SshPasswordAuth(
    [System.Security.SecureString]$Password,
    [string]$RuntimeDirectory
) {
    if ($null -eq $Password -or $Password.Length -eq 0) {
        throw "SSH 密码不能为空。"
    }

    $passwordPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $script:SshPasswordPlainText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }

    $script:SshAskPassPath = Join-Path $RuntimeDirectory "ssh-askpass-$PID.exe"
    $askPassClassName = "AisfSshAskPass_$([Guid]::NewGuid().ToString('N'))"
    $askPassSource = @"
using System;

public static class $askPassClassName
{
    public static void Main()
    {
        Console.Write(Environment.GetEnvironmentVariable("AISF_E2E_SSH_PASSWORD") ?? "");
    }
}
"@
    $null = Add-Type -TypeDefinition $askPassSource `
        -OutputAssembly $script:SshAskPassPath `
        -OutputType ConsoleApplication
    if (-not (Test-Path -LiteralPath $script:SshAskPassPath -PathType Leaf)) {
        throw "无法创建 SSH AskPass 辅助程序：$($script:SshAskPassPath)"
    }
    $script:SshPasswordEnabled = $true
}

function Push-SshPasswordEnvironment {
    if (-not $script:SshPasswordEnabled) {
        return $null
    }
    $state = [pscustomobject]@{
        Password = $env:AISF_E2E_SSH_PASSWORD
        AskPass = $env:SSH_ASKPASS
        AskPassRequire = $env:SSH_ASKPASS_REQUIRE
        Display = $env:DISPLAY
    }
    $env:AISF_E2E_SSH_PASSWORD = $script:SshPasswordPlainText
    $env:SSH_ASKPASS = $script:SshAskPassPath
    $env:SSH_ASKPASS_REQUIRE = "force"
    $env:DISPLAY = "AISF_E2E:0"
    return $state
}

function Pop-SshPasswordEnvironment([object]$State) {
    if ($null -eq $State) {
        return
    }
    $env:AISF_E2E_SSH_PASSWORD = $State.Password
    $env:SSH_ASKPASS = $State.AskPass
    $env:SSH_ASKPASS_REQUIRE = $State.AskPassRequire
    $env:DISPLAY = $State.Display
}

function Clear-SshPasswordAuth {
    if (-not [string]::IsNullOrWhiteSpace($script:SshAskPassPath) -and
        (Test-Path -LiteralPath $script:SshAskPassPath -PathType Leaf)) {
        Remove-Item -LiteralPath $script:SshAskPassPath -Force
    }
    $script:SshPasswordPlainText = $null
    $script:SshAskPassPath = $null
    $script:SshPasswordEnabled = $false
}

function Get-SshArguments([string]$RemoteCommand, [switch]$ForStartProcess) {
    $target = if ([string]::IsNullOrWhiteSpace($SshUser)) { $RemoteIp } else { "$SshUser@$RemoteIp" }
    $args = @(
        "-p", "$SshPort",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=6"
    )
    if ($script:SshPasswordEnabled) {
        $args += @(
            "-o", "BatchMode=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=1"
        )
    } else {
        $args += @("-o", "BatchMode=yes")
    }
    if ($ForStartProcess) {
        # Start-Process 会把 ArgumentList 拼成一条 Windows 命令行；显式包裹远端命令，
        # 防止其中的空格被本地参数解析器拆开。
        $remoteArgument = '"' + $RemoteCommand.Replace('"', '\"') + '"'
    } else {
        $remoteArgument = $RemoteCommand
    }
    $args += @($target, $remoteArgument)
    return $args
}

function Invoke-SshCommand([string]$RemoteCommand) {
    $authState = Push-SshPasswordEnvironment
    try {
        $sshArgs = Get-SshArguments $RemoteCommand
        $output = @(& ssh @sshArgs 2>&1)
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = $output
        }
    } finally {
        Pop-SshPasswordEnvironment $authState
    }
}

function Assert-SshContainerReady {
    $inside = @(
        'test -d /softwarePlatform/t00963426/UMModelCompress_backup'
        'command -v vllm >/dev/null'
        'command -v setsid >/dev/null'
    ) -join " && "
    $remote = "docker exec -i $(Quote-Bash $ContainerName) /bin/bash -lc $(Quote-Bash $inside)"
    $result = Invoke-SshCommand $remote
    if ($result.ExitCode -ne 0) {
        $detail = ($result.Output | Out-String).Trim()
        throw "SSH 登录或容器预检失败（用户 $SshUser，容器 $ContainerName）：$detail"
    }
    Write-Step "SSH 账密登录成功，容器 $ContainerName 已就绪，vLLM 将在容器内启动。"
}

function Start-VllmSsh(
    [string]$ModelPath,
    [string]$ModelName,
    [int]$Device,
    [int]$Port,
    [string]$Strat,
    [int]$Layer,
    [int]$Rate,
    [string]$PidFile,
    [string]$StdoutPath,
    [string]$StderrPath
) {
    $additional = @{
        llm_pruning_config = @{
            pruning_rate = $Rate
            pruning_layer = $Layer
            pruning_strat = $Strat
            max_decode_num = 5
        }
    } | ConvertTo-Json -Compress -Depth 4
    $compilation = '{"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[1,2,3,4,5]}'
    $chat = '{"enable_thinking":false}'

    $serviceCommand = @(
        "export ASCEND_RT_VISIBLE_DEVICES=$Device"
        'export PYTHONPATH=/softwarePlatform/t00963426/UMModelCompress_backup/vllm:$PYTHONPATH'
        'export PYTHONPATH=/softwarePlatform/t00963426/UMModelCompress_backup/vllm-ascend:$PYTHONPATH'
        'export PYTHONPATH=/softwarePlatform/t00963426/UMModelCompress_backup:$PYTHONPATH'
        'cd /softwarePlatform/t00963426/UMModelCompress_backup'
        "echo `$`$ > $(Quote-Bash $PidFile)"
        "exec vllm serve $(Quote-Bash $ModelPath) --host 0.0.0.0 --port $Port --data-parallel-size 1 --tensor-parallel-size 1 --served-model-name $(Quote-Bash $ModelName) --max-num-seqs 32 --max-model-len 3072 --max-num-batched-tokens 70000 --trust-remote-code --gpu-memory-utilization 0.7 --compilation-config $(Quote-Bash $compilation) --async-scheduling --default-chat-template-kwargs $(Quote-Bash $chat) --additional-config $(Quote-Bash $additional)"
    ) -join "; "
    $inside = "exec setsid /bin/bash -lc $(Quote-Bash $serviceCommand)"
    $remote = "docker exec -i $(Quote-Bash $ContainerName) /bin/bash -lc $(Quote-Bash $inside)"
    $authState = Push-SshPasswordEnvironment
    try {
        return Start-Process -FilePath "ssh" -ArgumentList (Get-SshArguments $remote -ForStartProcess) `
            -PassThru -NoNewWindow -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    } finally {
        Pop-SshPasswordEnvironment $authState
    }
}

function Stop-RemoteVllm([string]$PidFile, [string]$ExpectedModel, [int]$Port) {
    $quotedPidFile = Quote-Bash $PidFile
    $quotedModel = Quote-Bash $ExpectedModel
    $inside = 'if test -f ' + $quotedPidFile +
        '; then pid=$(cat ' + $quotedPidFile +
        '); if test -r /proc/$pid/cmdline && grep -aFq -- ' + $quotedModel + ' /proc/$pid/cmdline; then ' +
        'kill -TERM -- -$pid 2>/dev/null || true; ' +
        'for n in {1..30}; do kill -0 -- -$pid 2>/dev/null || break; sleep 1; done; ' +
        'kill -KILL -- -$pid 2>/dev/null || true; ' +
        'else echo "refusing to kill unexpected PID $pid" >&2; exit 7; fi; ' +
        'rm -f ' + $quotedPidFile + '; else exit 3; fi'
    $remote = "docker exec -i $(Quote-Bash $ContainerName) /bin/bash -lc $(Quote-Bash $inside)"
    try {
        $result = Invoke-SshCommand $remote
        if ($result.ExitCode -eq 3) {
            return
        } elseif ($result.ExitCode -ne 0) {
            $detail = ($result.Output | Out-String).Trim()
            Write-Warning "远端清理命令退出码为 $($result.ExitCode)（$PidFile）：$detail"
        } elseif (-not (Wait-TcpPortClosed $RemoteIp $Port 60)) {
            Write-Warning "远端进程已清理，但端口仍未关闭：${RemoteIp}:$Port"
        }
    } catch {
        Write-Warning "远端清理失败（$PidFile）：$($_.Exception.Message)"
    }
}

function Wait-ModelReady([string]$Ip, [int]$Port, [string]$ExpectedModel, [System.Diagnostics.Process]$SshProcess) {
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    $uri = "http://${Ip}:$Port/v1/models"
    while ((Get-Date) -lt $deadline) {
        if ($SshProcess.HasExited) {
            throw "SSH/vLLM 进程提前退出，退出码 $($SshProcess.ExitCode)。"
        }
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10
            if ($response.data.id -contains $ExpectedModel) {
                Write-Step "服务已就绪：$uri ($ExpectedModel)"
                return
            }
        } catch {
            # 启动期间连接失败属于正常重试。
        }
        Start-Sleep -Seconds 5
    }
    throw "等待服务超时：$uri ($ExpectedModel)"
}

function Wait-UvicornReady([int]$Port, [System.Diagnostics.Process]$Process) {
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    $uri = "http://127.0.0.1:$Port/openapi.json"
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            throw "uvicorn 进程提前退出，退出码 $($Process.ExitCode)。"
        }
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10
            Write-Step "uvicorn 已就绪：$uri"
            return
        } catch {
            # 启动期间连接失败属于正常重试。
        }
        Start-Sleep -Seconds 2
    }
    throw "等待 uvicorn 超时：$uri"
}

function Test-TcpPortOpen([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds = 1000) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync($HostName, $Port)
        if (-not $connect.Wait($TimeoutMilliseconds)) {
            return $false
        }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Assert-TcpPortFree([string]$HostName, [int]$Port, [string]$Description) {
    if (Test-TcpPortOpen $HostName $Port) {
        throw "$Description 端口已被占用：${HostName}:$Port"
    }
}

function Wait-TcpPortClosed([string]$HostName, [int]$Port, [int]$TimeoutSeconds = 60) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-TcpPortOpen $HostName $Port)) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return -not (Test-TcpPortOpen $HostName $Port)
}

function New-IsolatedProjectCopy(
    [string]$Source,
    [string]$Destination,
    [string]$CopyLog
) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $copyArgs = @(
        $Source,
        $Destination,
        "/E",
        "/XJ",
        "/R:1",
        "/W:1",
        "/COPY:DAT",
        "/DCOPY:DAT",
        "/NP",
        "/NFL",
        "/NDL",
        "/NJH",
        "/NJS",
        "/XD",
        ".venv",
        ".git",
        ".idea",
        "__pycache__",
        "e2e_logs",
        "e2e_workspaces",
        "/XF",
        "*.pyc",
        "*_out_*.xlsx"
    )
    & robocopy.exe @copyArgs 2>&1 | Out-File -LiteralPath $CopyLog -Encoding utf8
    $copyExitCode = $LASTEXITCODE
    if ($copyExitCode -ge 8) {
        throw "创建隔离项目副本失败，robocopy 退出码 $copyExitCode；详见 $CopyLog"
    }
}

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -ne $Process -and -not $Process.HasExited) {
        & taskkill.exe /PID $Process.Id /T /F | Out-Null
    }
}

function Add-JobFailure(
    [object]$Job,
    [string]$Message,
    [System.Collections.Generic.List[string]]$FailureList
) {
    if (-not $Job.Failed) {
        $Job.Failed = $true
        $Job.Failure = $Message
        $fullMessage = "$($Job.Id) : $Message"
        $FailureList.Add($fullMessage)
        Write-Warning $fullMessage
    }
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd("\")
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "项目根目录不存在：$ProjectRoot"
}
if ([string]::IsNullOrWhiteSpace($TestPath)) {
    $TestPath = Join-Path $ProjectRoot "test\modelTestV7_offline-v1.py"
}
$TestPath = [System.IO.Path]::GetFullPath($TestPath)
if (-not (Test-Path -LiteralPath $TestPath -PathType Leaf)) {
    throw "测试文件不存在：$TestPath"
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ProjectRoot "app\common\config.py"
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "配置文件不存在：$ConfigPath"
}
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    $PythonPath = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
}
$PythonPath = [System.IO.Path]::GetFullPath($PythonPath)
if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
    throw "虚拟环境 Python 不存在：$PythonPath"
}
if ($Strats.Count -eq 0 -or $PruningLayers.Count -eq 0 -or $PruningRates.Count -eq 0) {
    throw "三个超参数列表都不能为空。"
}
if ([string]::IsNullOrWhiteSpace($ExperimentName) -or
    $ExperimentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or
    $ExperimentName -in @(".", "..")) {
    throw "实验名称只能包含英文字母、数字、下划线、短横线和点，并且必须以字母或数字开头：$ExperimentName"
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $ProjectRoot "tests"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$experimentOutputDirectory = Join-Path $OutputRoot $ExperimentName
$projectPrefix = $ProjectRoot + [System.IO.Path]::DirectorySeparatorChar
if (-not $ConfigPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "配置文件必须位于项目根目录内，才能创建隔离副本：$ConfigPath"
}
if (-not $TestPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "测试文件必须位于项目根目录内，才能创建隔离副本：$TestPath"
}
$configRelativePath = $ConfigPath.Substring($projectPrefix.Length)
$testRelativePath = $TestPath.Substring($projectPrefix.Length)
$configOriginal = [System.IO.File]::ReadAllBytes($ConfigPath)
$testOriginal = [System.IO.File]::ReadAllBytes($TestPath)

$combinations = [System.Collections.Generic.List[object]]::new()
$seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($strat in $Strats) {
    foreach ($layer in $PruningLayers) {
        foreach ($rate in $PruningRates) {
            $id = "strat_$(Get-SafeIdPart $strat)_layer_${layer}_rate_${rate}"
            if (-not $seenIds.Add($id)) {
                throw "检测到重复任务 ID：$id。请去除重复超参数值。"
            }
            $combinations.Add([pscustomobject]@{
                Id = $id
                Strat = $strat
                Layer = $layer
                Rate = $rate
            })
        }
    }
}
$devicePool = @()
if ($DeviceIds.Count -gt 0) {
    $devicePool = @($DeviceIds)
    if ($devicePool.Count -lt 2) {
        throw "-DeviceIds 至少需要提供两张卡。"
    }
    if (($devicePool.Count % 2) -ne 0) {
        throw "-DeviceIds 的卡数必须是偶数，每个槽位固定使用两张卡。"
    }
    if (@($devicePool | Where-Object { $_ -lt 0 }).Count -gt 0) {
        throw "-DeviceIds 不能包含负数。"
    }
    if (@($devicePool | Select-Object -Unique).Count -ne $devicePool.Count) {
        throw "-DeviceIds 不能包含重复卡号。"
    }
} else {
    if ($FirstDevice -ge $TotalDevices) {
        throw "-FirstDevice=$FirstDevice 必须小于 -TotalDevices=$TotalDevices。"
    }
    $devicePool = @($FirstDevice..($TotalDevices - 1))
}

$slotCapacity = [int][Math]::Floor($devicePool.Count / 2)
if ($slotCapacity -lt 1) {
    throw "当前资源池不足两张卡，无法创建一个评测槽位。"
}
$effectiveConcurrency = [int][Math]::Min(
    $MaxConcurrency,
    [Math]::Min($slotCapacity, $combinations.Count)
)
if ($effectiveConcurrency -lt $MaxConcurrency) {
    Write-Step "资源池可提供 $slotCapacity 个槽位，本次实际并发数为 $effectiveConcurrency（请求上限 $MaxConcurrency）。"
}
if (($FirstPort + 2 * $effectiveConcurrency - 1) -gt 65535) {
    throw "vLLM 端口范围超过 65535。"
}
if (($UvicornPort + $effectiveConcurrency - 1) -gt 65535) {
    throw "uvicorn 端口范围超过 65535。"
}

$runToken = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID"
$logRoot = Join-Path (Join-Path (Join-Path $PSScriptRoot "e2e_logs") $ExperimentName) $runToken
$workspaceParent = Join-Path $PSScriptRoot "e2e_workspaces"
$workspaceRoot = Join-Path (Join-Path $workspaceParent $ExperimentName) $runToken
$lockMaterial = "$ProjectRoot|$RemoteIp|$FirstPort|$UvicornPort"
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $lockBytes = [System.Text.Encoding]::UTF8.GetBytes($lockMaterial)
    $lockHash = ([System.BitConverter]::ToString($sha256.ComputeHash($lockBytes))).Replace("-", "").Substring(0, 24)
} finally {
    $sha256.Dispose()
}
$runMutex = [System.Threading.Mutex]::new($false, "Local\AISF_VLM_E2E_$lockHash")
$lockAcquired = $false
try {
    $lockAcquired = $runMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $lockAcquired = $true
}
if (-not $lockAcquired) {
    $runMutex.Dispose()
    throw "检测到另一个相同项目/服务器/端口的评测脚本正在运行。"
}
try {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $workspaceRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $experimentOutputDirectory -Force | Out-Null
} catch {
    $runMutex.ReleaseMutex()
    $runMutex.Dispose()
    throw
}
$failures = [System.Collections.Generic.List[string]]::new()
$preserveWorkspaces = $KeepWorkspaces -or $KeepModifiedFiles
if ($KeepModifiedFiles) {
    Write-Warning "-KeepModifiedFiles 在并发版中等同于 -KeepWorkspaces；原项目文件始终不会被修改。"
}

try {
    Initialize-SshPasswordAuth $SshPassword $workspaceRoot
    Assert-SshContainerReady

    for ($offset = 0; $offset -lt $combinations.Count; $offset += $effectiveConcurrency) {
        $batchCount = [Math]::Min($effectiveConcurrency, $combinations.Count - $offset)
        $batchNumber = [int]($offset / $effectiveConcurrency) + 1
        $batch = [System.Collections.Generic.List[object]]::new()
        Write-Step "启动第 $batchNumber 批，共 $batchCount 组并发任务"

        try {
            # 为本批每个槽位写入独立配置，并尽快启动全部 vLLM。
            for ($slot = 0; $slot -lt $batchCount; $slot++) {
                $combo = $combinations[$offset + $slot]
                $workerRoot = Join-Path $workspaceRoot $combo.Id
                $workerConfig = Join-Path $workerRoot $configRelativePath
                $workerTest = Join-Path $workerRoot $testRelativePath
                $runLogDir = Join-Path $logRoot $combo.Id
                $basePort = $FirstPort + 2 * $slot
                $sftPort = $basePort + 1
                $uvicornJobPort = $UvicornPort + $slot
                $baseDevice = $devicePool[2 * $slot]
                $sftDevice = $devicePool[2 * $slot + 1]
                $baseModel = "Qwen3.5-4B-$($combo.Id)"
                $sftModel = "Qwen3.5-4B-sft-$($combo.Id)"
                $outputPath = Join-Path $experimentOutputDirectory "0713python框架的大模型结果-产品侧0713_out_$($combo.Id).xlsx"
                $basePidFile = "/tmp/vllm-$runToken-$($combo.Id)-base.pid"
                $sftPidFile = "/tmp/vllm-$runToken-$($combo.Id)-sft.pid"
                New-Item -ItemType Directory -Path $runLogDir -Force | Out-Null

                $job = [pscustomobject]@{
                    Id = $combo.Id
                    Strat = $combo.Strat
                    Layer = $combo.Layer
                    Rate = $combo.Rate
                    Slot = $slot
                    WorkerRoot = $workerRoot
                    WorkerConfig = $workerConfig
                    WorkerTest = $workerTest
                    LogDir = $runLogDir
                    OutputPath = $outputPath
                    BaseDevice = $baseDevice
                    SftDevice = $sftDevice
                    BasePort = $basePort
                    SftPort = $sftPort
                    UvicornPort = $uvicornJobPort
                    BaseModel = $baseModel
                    SftModel = $sftModel
                    BasePidFile = $basePidFile
                    SftPidFile = $sftPidFile
                    BaseSsh = $null
                    SftSsh = $null
                    UvicornProcess = $null
                    TestProcess = $null
                    TestStartedAt = $null
                    Failed = $false
                    Failure = ""
                }
                $batch.Add($job)

                try {
                    New-IsolatedProjectCopy $ProjectRoot $workerRoot (Join-Path $runLogDir "workspace-copy.log")
                    [System.IO.File]::WriteAllBytes($workerConfig, $configOriginal)
                    [System.IO.File]::WriteAllBytes($workerTest, $testOriginal)
                    Set-LocalConfiguration $workerConfig $RemoteIp $basePort $baseModel $sftModel
                    Set-TestConfiguration $workerTest $outputPath $uvicornJobPort

                    [pscustomobject]@{
                        id = $job.Id
                        experiment_name = $ExperimentName
                        experiment_output_directory = $experimentOutputDirectory
                        slot_capacity = $slotCapacity
                        effective_concurrency = $effectiveConcurrency
                        device_pool = $devicePool
                        strat = $job.Strat
                        pruning_layer = $job.Layer
                        pruning_rate = $job.Rate
                        remote_ip = $RemoteIp
                        base_device = $baseDevice
                        base_port = $basePort
                        base_model = $baseModel
                        sft_device = $sftDevice
                        sft_port = $sftPort
                        sft_model = $sftModel
                        uvicorn_port = $uvicornJobPort
                        test_url = "http://127.0.0.1:$uvicornJobPort/v1/chat/completions"
                        output_file = $outputPath
                        output_preexisting = (Test-Path -LiteralPath $outputPath -PathType Leaf)
                    } | ConvertTo-Json -Depth 3 |
                        Set-Content -LiteralPath (Join-Path $runLogDir "metadata.json") -Encoding utf8

                    Assert-TcpPortFree $RemoteIp $basePort "基模 vLLM"
                    Assert-TcpPortFree $RemoteIp $sftPort "SFT vLLM"
                    $job.BaseSsh = Start-VllmSsh `
                        "/softwarePlatform/c00879303/Qwen3-5/Qwen3.5-4B" $baseModel `
                        $baseDevice $basePort $combo.Strat $combo.Layer $combo.Rate `
                        $basePidFile `
                        (Join-Path $runLogDir "vllm-base.out.log") (Join-Path $runLogDir "vllm-base.err.log")
                    $job.SftSsh = Start-VllmSsh `
                        "/softwarePlatform/models_directory/Qwen3.5-4B-sft-v002" $sftModel `
                        $sftDevice $sftPort $combo.Strat $combo.Layer $combo.Rate `
                        $sftPidFile `
                        (Join-Path $runLogDir "vllm-sft.out.log") (Join-Path $runLogDir "vllm-sft.err.log")
                    Write-Step "$($job.Id)：卡 $baseDevice/$sftDevice，vLLM $basePort/$sftPort，uvicorn $uvicornJobPort"
                } catch {
                    Add-JobFailure $job $_.Exception.Message $failures
                }
            }

            # vLLM 已经全部并发启动；逐个确认时，其余服务仍在后台并行加载。
            foreach ($job in $batch) {
                if ($job.Failed) {
                    continue
                }
                try {
                    Wait-ModelReady $RemoteIp $job.BasePort $job.BaseModel $job.BaseSsh
                    Wait-ModelReady $RemoteIp $job.SftPort $job.SftModel $job.SftSsh
                    Start-Sleep -Seconds 2
                    $job.BaseSsh.Refresh()
                    $job.SftSsh.Refresh()
                    if ($job.BaseSsh.HasExited -or $job.SftSsh.HasExited) {
                        throw "健康检查后 SSH/vLLM 进程意外退出。"
                    }
                } catch {
                    Add-JobFailure $job $_.Exception.Message $failures
                }
            }

            # 每个 uvicorn 从自己的项目副本读取配置，端口和模型地址完全隔离。
            foreach ($job in $batch) {
                if ($job.Failed) {
                    continue
                }
                try {
                    Assert-TcpPortFree "127.0.0.1" $job.UvicornPort "uvicorn"
                    $job.UvicornProcess = Start-Process -FilePath $PythonPath `
                        -ArgumentList @("-m", "uvicorn", "app.main:app", "--app-dir", "`"$($job.WorkerRoot)`"", "--host", "0.0.0.0", "--port", "$($job.UvicornPort)", "--workers", "$UvicornWorkers") `
                        -WorkingDirectory $job.WorkerRoot -PassThru -NoNewWindow `
                        -RedirectStandardOutput (Join-Path $job.LogDir "uvicorn.out.log") `
                        -RedirectStandardError (Join-Path $job.LogDir "uvicorn.err.log")
                } catch {
                    Add-JobFailure $job $_.Exception.Message $failures
                }
            }
            foreach ($job in $batch) {
                if ($job.Failed) {
                    continue
                }
                try {
                    Wait-UvicornReady $job.UvicornPort $job.UvicornProcess
                    Start-Sleep -Seconds 1
                    $job.UvicornProcess.Refresh()
                    if ($job.UvicornProcess.HasExited) {
                        throw "健康检查后 uvicorn 进程意外退出。"
                    }
                } catch {
                    Add-JobFailure $job $_.Exception.Message $failures
                }
            }

            # 四个测试进程先全部启动，再统一等待，确保评测主体真正并行。
            foreach ($job in $batch) {
                if ($job.Failed) {
                    continue
                }
                try {
                    $oldPythonPath = $env:PYTHONPATH
                    try {
                        $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($oldPythonPath)) {
                            $job.WorkerRoot
                        } else {
                            "$($job.WorkerRoot);$oldPythonPath"
                        }
                        $quotedTestPath = '"' + $job.WorkerTest.Replace('"', '\"') + '"'
                        $job.TestStartedAt = Get-Date
                        $job.TestProcess = Start-Process -FilePath $PythonPath `
                            -ArgumentList @($quotedTestPath) -WorkingDirectory $job.WorkerRoot `
                            -PassThru -NoNewWindow `
                            -RedirectStandardOutput (Join-Path $job.LogDir "test.out.log") `
                            -RedirectStandardError (Join-Path $job.LogDir "test.err.log")
                    } finally {
                        $env:PYTHONPATH = $oldPythonPath
                    }
                    Write-Step "$($job.Id)：测试已启动，PID $($job.TestProcess.Id)"
                } catch {
                    Add-JobFailure $job $_.Exception.Message $failures
                }
            }

            while ($true) {
                $hasRunningTest = $false
                foreach ($job in $batch) {
                    if ($job.Failed -or $null -eq $job.TestProcess) {
                        continue
                    }
                    $job.TestProcess.Refresh()
                    if (-not $job.TestProcess.HasExited) {
                        if ($TestTimeoutSeconds -gt 0 -and
                            ((Get-Date) - $job.TestStartedAt).TotalSeconds -ge $TestTimeoutSeconds) {
                            Stop-ProcessTree $job.TestProcess
                            Add-JobFailure $job "测试运行超过 $TestTimeoutSeconds 秒，已终止。" $failures
                        } else {
                            $hasRunningTest = $true
                        }
                    }
                }
                if (-not $hasRunningTest) {
                    break
                }
                Start-Sleep -Seconds 5
            }

            foreach ($job in $batch) {
                if ($job.Failed -or $null -eq $job.TestProcess) {
                    continue
                }
                if ($job.TestProcess.ExitCode -ne 0) {
                    Add-JobFailure $job "测试脚本退出码为 $($job.TestProcess.ExitCode)。" $failures
                } elseif (-not (Test-Path -LiteralPath $job.OutputPath -PathType Leaf)) {
                    Add-JobFailure $job "测试退出成功，但未找到输出文件：$($job.OutputPath)" $failures
                } else {
                    Write-Step "任务完成：$($job.Id)，输出：$($job.OutputPath)"
                }
            }
        } finally {
            Write-Step "清理第 $batchNumber 批的测试、uvicorn 和远端 vLLM 服务"
            foreach ($job in $batch) {
                Stop-ProcessTree $job.TestProcess
                Stop-ProcessTree $job.UvicornProcess
            }
            foreach ($job in $batch) {
                Stop-RemoteVllm $job.BasePidFile $job.BaseModel $job.BasePort
                Stop-RemoteVllm $job.SftPidFile $job.SftModel $job.SftPort
                Stop-ProcessTree $job.BaseSsh
                Stop-ProcessTree $job.SftSsh
            }
            if (-not $preserveWorkspaces) {
                $resolvedRunWorkspace = [System.IO.Path]::GetFullPath($workspaceRoot).TrimEnd("\") + "\"
                foreach ($job in $batch) {
                    if (Test-Path -LiteralPath $job.WorkerRoot -PathType Container) {
                        $resolvedJobWorkspace = [System.IO.Path]::GetFullPath($job.WorkerRoot)
                        if (-not $resolvedJobWorkspace.StartsWith($resolvedRunWorkspace, [System.StringComparison]::OrdinalIgnoreCase)) {
                            throw "拒绝清理意外的任务工作目录：$resolvedJobWorkspace"
                        }
                        Remove-Item -LiteralPath $resolvedJobWorkspace -Recurse -Force
                    }
                }
            }
        }

        $batchFailed = @($batch | Where-Object { $_.Failed }).Count -gt 0
        if ($batchFailed -and -not $ContinueOnError) {
            throw "第 $batchNumber 批存在失败任务，已停止后续批次。使用 -ContinueOnError 可继续。"
        }
    }
} finally {
    try {
        try {
            Clear-SshPasswordAuth
        } catch {
            Write-Warning "清理 SSH 密码辅助环境失败：$($_.Exception.Message)"
        }
        if (-not $preserveWorkspaces -and (Test-Path -LiteralPath $workspaceRoot -PathType Container)) {
            $resolvedWorkspace = [System.IO.Path]::GetFullPath($workspaceRoot)
            $resolvedParent = [System.IO.Path]::GetFullPath($workspaceParent).TrimEnd("\") + "\"
            if (-not $resolvedWorkspace.StartsWith($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "拒绝清理意外的工作目录：$resolvedWorkspace"
            }
            Remove-Item -LiteralPath $resolvedWorkspace -Recurse -Force
            Write-Step "已清理隔离项目副本；原项目文件未修改"
        } elseif ($preserveWorkspaces) {
            Write-Step "已保留隔离项目副本：$workspaceRoot"
        }
    } finally {
        if ($lockAcquired) {
            $runMutex.ReleaseMutex()
            $lockAcquired = $false
        }
        $runMutex.Dispose()
    }
}

if ($failures.Count -gt 0) {
    throw "共有 $($failures.Count) 个任务失败：`n$($failures -join "`n")`n日志目录：$logRoot"
}
Write-Step "全部 $($combinations.Count) 个超参数组合评测完成。日志目录：$logRoot"












