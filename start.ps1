#requires -Version 5.1

<#
用途：
  这是给你本机自用的 CLIProxyAPI 一键启动脚本。
  它负责做几件事：
  1. 检查 Go 是否安装
  2. 检查 config.yaml 是否存在，不存在时从 config.example.yaml 复制
  3. 读取当前配置中的 host、port、auth-dir
  4. 检查 Claude / Codex / Gemini 的 OAuth 登录状态
  5. 启动 CLIProxyAPI 服务
  6. 服务启动后自动打开浏览器管理界面

常用命令：
  1. 只检查状态，不启动：
     .\start.ps1 -StatusOnly

  2. 一键启动，并自动打开浏览器管理界面（默认就在当前终端运行）：
     .\start.ps1

  3. 如需新开一个 PowerShell 窗口运行服务：
     .\start.ps1 -NewWindow

  4. 打开终端管理界面 TUI：
     .\start.ps1 -Tui

  5. 先执行某个 OAuth 登录：
     .\start.ps1 -Login claude
     .\start.ps1 -Login codex
     .\start.ps1 -Login gemini

说明：
  - 这个脚本不会“自动替你完成所有 OAuth 授权”，因为 Claude / Codex / Gemini
    本身就是三套独立登录流程，仍然需要你在浏览器里分别确认。
  - 但它能把环境检查、状态提示、启动服务、打开管理页这些重复动作统一起来。
#>

[CmdletBinding()]
# 参数说明：
# -Login       先执行指定 provider 的 OAuth 登录，可选：claude / codex / gemini
# -StatusOnly  只检查环境和登录状态，不启动服务
# -Tui         启动 TUI 终端管理界面（内部会自动追加 -standalone）
# -Foreground  强制在当前 PowerShell 窗口前台运行（现在默认就是这个行为）
# -NewWindow   新开一个 PowerShell 窗口运行服务
# -NoBrowser   启动后不自动打开浏览器管理界面
param(
    [ValidateSet("claude", "codex", "gemini")]
    [string]$Login,
    [switch]$StatusOnly,
    [switch]$Tui,
    [switch]$Foreground,
    [switch]$NewWindow,
    [switch]$NoBrowser
)

# 自用提示：
# 这里可以填你自己记住的管理界面密码。
# 原因是 CLIProxyAPI 首次启动后会把 config.yaml 里的明文密码自动哈希，
# 之后脚本无法再从配置文件反推出原始密码。
# 你自己本机用的话，直接在这里保留明文提示最省事。
$KnownManagementPassword = "123456"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 统一输出前缀，避免后面看不清脚本自己的提示
function Write-Step {
    param([string]$Message)
    Write-Host "[CLIProxyAPI] $Message"
}

# 从 config.yaml 的文本中按正则提取一个简单值。
# 这里只处理本脚本需要的少数字段，不做完整 YAML 解析。
function Get-ConfigValue {
    param(
        [string[]]$Lines,
        [string]$Pattern,
        [string]$Default = ""
    )

    foreach ($line in $Lines) {
        if ($line -match $Pattern) {
            return $Matches[1].Trim()
        }
    }
    return $Default
}

# 把 auth-dir 转成 Windows 下的绝对路径。
# 支持 "~/.cli-proxy-api" 这种写法。
function Resolve-AuthDir {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ""
    }

    $trimmed = $PathValue.Trim()
    if ($trimmed.StartsWith("~")) {
        $userHome = [Environment]::GetFolderPath("UserProfile")
        $suffix = $trimmed.Substring(1).TrimStart("\", "/")
        if ([string]::IsNullOrWhiteSpace($suffix)) {
            return $userHome
        }
        return [System.IO.Path]::GetFullPath((Join-Path $userHome $suffix))
    }

    return [System.IO.Path]::GetFullPath($trimmed)
}

# 获取管理界面密码提示。
# 优先使用脚本顶部手工指定的已知密码；
# 如果没有指定，再尝试从 config.yaml 里读取明文 secret-key；
# 如果配置里已经是 bcrypt 哈希，则只能返回空，无法反推明文。
function Get-ManagementPasswordHint {
    param(
        [string]$ConfiguredSecret,
        [string]$KnownPassword
    )

    if (-not [string]::IsNullOrWhiteSpace($KnownPassword)) {
        return $KnownPassword.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($ConfiguredSecret)) {
        return ""
    }

    $trimmed = $ConfiguredSecret.Trim()
    if ($trimmed -match '^\$2[aby]\$') {
        return ""
    }

    return $trimmed
}

# 统计认证目录里各 provider 的 JSON 凭据数量。
# 这里只看 Claude / Codex / Gemini，方便你快速判断哪些已经登录过。
function Get-ProviderStatus {
    param([string]$AuthDir)

    $result = [ordered]@{
        claude = 0
        codex  = 0
        gemini = 0
    }

    if ([string]::IsNullOrWhiteSpace($AuthDir) -or -not (Test-Path -LiteralPath $AuthDir)) {
        return $result
    }

    $files = Get-ChildItem -LiteralPath $AuthDir -Recurse -File -Filter *.json -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        try {
            $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $provider = [string]$json.type
            if ($result.Contains($provider)) {
                $result[$provider]++
            }
        } catch {
            continue
        }
    }

    return $result
}

# 检查 HTTP 服务是否已经可访问。
function Test-HTTPReady {
    param([string]$Url)

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
    } catch {
        return $false
    }
}

# 在指定时间内轮询，等待服务真正起来。
function Wait-ForService {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-HTTPReady -Url $Url) {
            return $true
        }
        Start-Sleep -Milliseconds 800
    }
    return $false
}

# 获取当前机器最适合提供给局域网客户端使用的 IPv4 地址。
# 优先选择带 IPv4 默认网关的网卡，其次选择常见私网地址，避免把虚拟网卡地址全都打印出来。
function Get-LanIPv4Addresses {
    $candidates = New-Object 'System.Collections.Generic.List[object]'

    foreach ($networkInterface in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($networkInterface.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
            continue
        }
        if ($networkInterface.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) {
            continue
        }
        if ($networkInterface.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) {
            continue
        }

        $ipProperties = $networkInterface.GetIPProperties()
        $hasIpv4Gateway = @(
            $ipProperties.GatewayAddresses | Where-Object {
                $_.Address -and
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                $_.Address.ToString() -ne '0.0.0.0'
            }
        ).Count -gt 0

        foreach ($unicastAddress in $ipProperties.UnicastAddresses) {
            $address = $unicastAddress.Address
            if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                continue
            }

            $addressText = $address.ToString()
            if ($addressText.StartsWith('169.254.')) {
                continue
            }

            $isPrivateAddress =
                $addressText.StartsWith('10.') -or
                $addressText.StartsWith('192.168.') -or
                ($addressText -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.')

            $priority = 0
            if ($hasIpv4Gateway) {
                $priority += 100
            }
            if ($isPrivateAddress) {
                $priority += 10
            }
            if ($networkInterface.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ethernet) {
                $priority += 2
            }
            if ($networkInterface.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) {
                $priority += 2
            }

            $candidates.Add([PSCustomObject]@{
                Address  = $addressText
                Priority = $priority
            }) | Out-Null
        }
    }

    if ($candidates.Count -eq 0) {
        return @()
    }

    $bestPriority = ($candidates | Measure-Object -Property Priority -Maximum).Maximum
    return @(
        $candidates |
            Where-Object { $_.Priority -eq $bestPriority } |
            Sort-Object Address |
            Select-Object -Unique -ExpandProperty Address
    )
}

# 在启动前打印给人看的关键信息，避免服务一启动就被日志刷屏看不到入口地址。
function Show-StartupHints {
    param(
        [string[]]$BaseUrls,
        [string[]]$ManagementUrls,
        [hashtable]$ProviderStatus,
        [string]$ManagementPassword
    )

    $baseUrlList = @($BaseUrls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $managementUrlList = @($ManagementUrls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    Write-Host ""
    Write-Host "================ 启动说明 ================"

    if ($managementUrlList.Count -le 1) {
        Write-Host ("管理界面地址：{0}" -f $managementUrlList[0])
    } else {
        Write-Host "管理界面地址："
        foreach ($url in $managementUrlList) {
            Write-Host ("  - {0}" -f $url)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ManagementPassword)) {
        Write-Host ("管理界面密码：{0}" -f $ManagementPassword)
    } else {
        Write-Host "管理界面密码：当前无法从配置中反推出明文，请以你自己设置的密码为准"
    }

    if ($baseUrlList.Count -le 1) {
        Write-Host ("OpenAI 兼容地址：{0}/v1" -f $baseUrlList[0])
        Write-Host ("Gemini 兼容地址：{0}/v1beta" -f $baseUrlList[0])
    } else {
        Write-Host "OpenAI 兼容地址："
        foreach ($url in $baseUrlList) {
            Write-Host ("  - {0}/v1" -f $url)
        }

        Write-Host "Gemini 兼容地址："
        foreach ($url in $baseUrlList) {
            Write-Host ("  - {0}/v1beta" -f $url)
        }
    }

    Write-Host "用途说明：先打开管理界面，再在里面做 OAuth 登录或查看配置。"
    if ($managementUrlList.Count -gt 1) {
        Write-Host "局域网设备调用 /v1 时，请在客户端里填写上面的 192/10/172 地址，不要填写 127.0.0.1。"
    }

    if ($ProviderStatus.claude -eq 0 -and $ProviderStatus.codex -eq 0 -and $ProviderStatus.gemini -eq 0) {
        Write-Host "当前还没有任何 Claude / Codex / Gemini 登录记录。"
        Write-Host "你可以这样登录："
        Write-Host "  1. 打开上面的管理界面，在 OAuth 页面里点对应 provider"
        Write-Host "  2. 或者直接运行命令："
        Write-Host "     .\start.ps1 -Login claude"
        Write-Host "     .\start.ps1 -Login codex"
        Write-Host "     .\start.ps1 -Login gemini"
    }

    Write-Host "========================================="
    Write-Host ""
}

# 按 provider 调用对应的 OAuth 登录命令。
function Invoke-LoginFlow {
    param(
        [string]$Provider,
        [string]$ConfigPath
    )

    $flag = switch ($Provider) {
        "claude" { "-claude-login" }
        "codex" { "-codex-login" }
        "gemini" { "-login" }
        default { throw "Unsupported provider: $Provider" }
    }

    Write-Step "开始执行 $Provider 的 OAuth 登录流程..."
    & go run .\cmd\server -config $ConfigPath $flag
}

# 定位当前仓库根目录，并强制切到这里执行，避免相对路径失效。
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $repoRoot

$configPath = Join-Path $repoRoot "config.yaml"
$exampleConfigPath = Join-Path $repoRoot "config.example.yaml"

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw "未检测到 Go，请先安装 Go 并确保 go 已加入 PATH。"
}

if (-not (Test-Path -LiteralPath $configPath)) {
    if (-not (Test-Path -LiteralPath $exampleConfigPath)) {
        throw "未找到 config.yaml，同时也缺少 config.example.yaml，无法自动初始化配置。"
    }
    Write-Step "未找到 config.yaml，正在从 config.example.yaml 自动复制..."
    Copy-Item -LiteralPath $exampleConfigPath -Destination $configPath
}

$configLines = Get-Content -LiteralPath $configPath
$serverHost = Get-ConfigValue -Lines $configLines -Pattern '^\s*host:\s*"?([^"#]*?)"?\s*$'
$portText = Get-ConfigValue -Lines $configLines -Pattern '^\s*port:\s*([0-9]+)\s*$' -Default "8317"
$authDirRaw = Get-ConfigValue -Lines $configLines -Pattern '^\s*auth-dir:\s*"?([^"#]+?)"?\s*$' -Default "~/.cli-proxy-api"
$managementSecretRaw = Get-ConfigValue -Lines $configLines -Pattern '^\s*secret-key:\s*"?([^"#]+?)"?\s*$'
$allowRemoteText = Get-ConfigValue -Lines $configLines -Pattern '^\s*allow-remote:\s*(true|false)\s*$' -Default "false"

$port = [int]$portText
$authDir = Resolve-AuthDir -PathValue $authDirRaw
$managementPasswordHint = Get-ManagementPasswordHint -ConfiguredSecret $managementSecretRaw -KnownPassword $KnownManagementPassword
$allowRemote = $allowRemoteText -eq "true"
$bindAllInterfaces = [string]::IsNullOrWhiteSpace($serverHost) -or $serverHost -eq "0.0.0.0" -or $serverHost -eq "::"
$displayListenAddress = if ($bindAllInterfaces) { "全部网卡" } else { $serverHost.Trim() }
$baseUrl = if ($bindAllInterfaces) { "http://127.0.0.1:{0}" -f $port } else { "http://{0}:{1}" -f $serverHost.Trim(), $port }
$managementUrl = "$baseUrl/management.html"
$baseUrls = New-Object 'System.Collections.Generic.List[string]'
$baseUrls.Add($baseUrl) | Out-Null
if ($bindAllInterfaces) {
    foreach ($lanAddress in Get-LanIPv4Addresses) {
        $lanBaseUrl = "http://{0}:{1}" -f $lanAddress, $port
        if (-not $baseUrls.Contains($lanBaseUrl)) {
            $baseUrls.Add($lanBaseUrl) | Out-Null
        }
    }
}
$managementUrls = if ($allowRemote) {
    @($baseUrls | ForEach-Object { "$_/management.html" })
} else {
    @($managementUrl)
}
$providerStatus = Get-ProviderStatus -AuthDir $authDir

Write-Step ("Go 版本：{0}" -f ((go version) -replace '^go version\s+', ''))
Write-Step "配置文件：$configPath"
Write-Step "监听地址：$displayListenAddress"
Write-Step "监听端口：$port"
Write-Step "认证目录：$authDir"
Write-Step ("OAuth 状态：Claude={0}，Codex={1}，Gemini={2}" -f $providerStatus.claude, $providerStatus.codex, $providerStatus.gemini)

if ($Login) {
    Invoke-LoginFlow -Provider $Login -ConfigPath $configPath
    $providerStatus = Get-ProviderStatus -AuthDir $authDir
    Write-Step ("更新后的 OAuth 状态：Claude={0}，Codex={1}，Gemini={2}" -f $providerStatus.claude, $providerStatus.codex, $providerStatus.gemini)
}

if ($StatusOnly) {
    Write-Step "状态检查完成。"
    return
}

# 默认就在当前终端前台运行，只有显式指定 -NewWindow 时才新开窗口。
if (-not $PSBoundParameters.ContainsKey("Foreground") -and -not $PSBoundParameters.ContainsKey("NewWindow")) {
    $Foreground = $true
}

$rootReady = Test-HTTPReady -Url "$baseUrl/"
if ($rootReady) {
    Write-Step "检测到服务已经在运行。"
    if (-not $NoBrowser -and -not $Tui) {
        Start-Process $managementUrl | Out-Null
        Write-Step "已打开管理界面：$managementUrl"
    }
    return
}

$serverArgs = @("run", ".\cmd\server", "-config", ".\config.yaml")
if ($Tui) {
    $serverArgs += @("-tui", "-standalone")
}

if ($Foreground -or -not $NewWindow) {
    if (-not $Tui) {
        Show-StartupHints -BaseUrls $baseUrls.ToArray() -ManagementUrls $managementUrls -ProviderStatus $providerStatus -ManagementPassword $managementPasswordHint
    }
    Write-Step "正在当前终端前台启动服务..."
    & go @serverArgs
    return
}

$argText = ($serverArgs | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
$commandText = "Set-Location -LiteralPath '$repoRoot'; go $argText"

Write-Step "正在新开 PowerShell 窗口启动服务..."
Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoExit",
    "-ExecutionPolicy", "Bypass",
    "-Command", $commandText
) | Out-Null

if (-not $Tui) {
    if (Wait-ForService -Url "$baseUrl/") {
        Write-Step "服务已就绪：$baseUrl"
        if (-not $NoBrowser) {
            Start-Process $managementUrl | Out-Null
            Write-Step "已打开管理界面：$managementUrl"
        }
    } else {
        Write-Step "服务在 30 秒内未成功就绪，请查看新打开的 PowerShell 窗口日志。"
    }
}
