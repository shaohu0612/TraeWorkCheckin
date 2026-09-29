# ====================================================
# TraeWorkCheckin - 自动签到管理控制台 (PowerShell 交互式)
# ====================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

try {
    $Host.UI.RawUI.WindowTitle = "TraeWorkCheckin - 自动签到管理控制台"
} catch {}

$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if (-not $scriptDir) {
    $scriptDir = (Get-Location).Path
}

function Get-UserStartupDir {
    $dir = [Environment]::GetFolderPath('Startup')
    if (-not $dir) {
        $dir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    }
    if (-not $dir) {
        $dir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    }
    return $dir
}

function Invoke-InstallTask {
    param([bool]$interactive = $true)
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "   TraeWorkCheckin - 安装全自动双轨签到系统" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[处理中] 正在配置系统启动项、00:00:30 定时任务并清理旧任务..." -ForegroundColor DarkGray

    $ws = New-Object -ComObject WScript.Shell
    $startupDir = Get-UserStartupDir

    # 1. 注册持久化 AUMID，保障 Windows 原生通知权限与右下角横幅正常展示
    $aumidKey = 'HKCU:\Software\Classes\AppUserModelId\TraeWorkCheckin'
    try {
        if (-not (Test-Path $aumidKey)) {
            New-Item -Path $aumidKey -Force | Out-Null
        }
        Set-ItemProperty -Path $aumidKey -Name 'DisplayName' -Value 'TraeWork 签到助手' -Type String -ErrorAction SilentlyContinue
    } catch {}

    # 2. 先清理可能存在的旧版本或同名快捷方式
    $lnkPath = Join-Path $startupDir 'TraeWorkCheckin.lnk'
    $oldLnkPath = Join-Path $startupDir 'TraeWorkAutoCheckin.lnk'
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path $oldLnkPath) { Remove-Item $oldLnkPath -Force -ErrorAction SilentlyContinue }

    # 3. 极速清理所有带有 TraeWork 字样的旧计划任务（采用 schtasks，毫秒级响应，杜绝卡顿）
    schtasks /Delete /TN 'TraeWorkCheckin_Daily' /F 2>$null | Out-Null
    schtasks /Delete /TN 'TraeWorkCheckin_Retry' /F 2>$null | Out-Null
    schtasks /Delete /TN 'TraeWorkCheckin' /F 2>$null | Out-Null
    schtasks /Delete /TN 'TraeWork每日签到' /F 2>$null | Out-Null
    schtasks /Delete /TN 'TraeWorkAutoCheckin' /F 2>$null | Out-Null

    # 4. 创建开机自启动快捷方式（指向无黑框静默执行器）
    $vbsPath = Join-Path $scriptDir 'run_traework_checkin_silent.vbs'
    $wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path $wscriptExe)) { $wscriptExe = 'wscript.exe' }

    $lnk = $ws.CreateShortcut($lnkPath)
    if (Test-Path $vbsPath) {
        $lnk.TargetPath = $wscriptExe
        $lnk.Arguments = "//B //Nologo `"$vbsPath`""
    } else {
        $lnk.TargetPath = Join-Path $scriptDir 'run_traework_checkin.cmd'
        $lnk.Arguments = '--silent'
    }
    $lnk.WorkingDirectory = $scriptDir
    $lnk.WindowStyle = 7 # 7 = 最小化后台静默启动
    $lnk.Description = 'TraeWork 每日自动检测签到 (双轨保障)'
    $lnk.Save()

    # 5. 配置每日 00:00:30 定时触发任务（作为全天在线/通宵在线的即时签到补充）
    $dailyTaskName = 'TraeWorkCheckin_Daily'
    if (Test-Path $vbsPath) {
        $taskTarget = "`"$wscriptExe`" //B //Nologo `"$vbsPath`""
    } else {
        $cmdRunner = Join-Path $scriptDir 'run_traework_checkin.cmd'
        $taskTarget = "`"$cmdRunner`" --silent"
    }
    schtasks /Create /TN $dailyTaskName /SC DAILY /ST 00:00:30 /TR $taskTarget /F 2>$null | Out-Null

    $dailyInstalled = ($LASTEXITCODE -eq 0)

    Write-Host ""
    if (Test-Path $lnkPath) {
        Write-Host "[成功] TraeWorkCheckin 双轨自动签到系统已成功安装！" -ForegroundColor Green
        Write-Host ""
        Write-Host "运行机制与双轨兜底保障：" -ForegroundColor Cyan
        Write-Host "  1. 轨道一（开机自启）：每次开机登录 Windows 桌面后，系统在后台静默运行检测签到；" -ForegroundColor Gray
        Write-Host "  2. 轨道二（每日零点）：每日 00:00:30 自动触发签到，若电脑夜间在线第一时间完成领取；" -ForegroundColor Gray
        Write-Host "  3. 智能互补与防风控：每日只要计算机曾在线，即可确保签到成功；已签到秒级跳过，不发多余请求；" -ForegroundColor Gray
        Write-Host "  4. 网络异步自愈：若启动时尚未联网，脚本自动低功耗等待网络就绪（最长 300 秒）；" -ForegroundColor Gray
        Write-Host "  5. 原生系统反馈：签到完成或跳过后，屏幕右下角自动弹出 Windows 原生 Toast 通知。" -ForegroundColor Gray
        if (-not $dailyInstalled) {
            Write-Host "  [提示] 每日 00:00:30 计划任务配置受限，但开机自启动项已正常就绪。" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[失败] 快捷方式生成失败，请检查启动目录权限。" -ForegroundColor Red
    }

    if ($interactive) {
        Write-Host ""
        Write-Host "----------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "请按任意键返回主菜单..." -ForegroundColor Yellow
        try {
            while ([Console]::KeyAvailable) { [Console]::ReadKey($true) > $null }
            if (-not [Console]::IsInputRedirected) {
                [Console]::ReadKey($true) > $null
            } else {
                Read-Host "按回车键返回主菜单" > $null
            }
        } catch {
            Read-Host "按回车键返回主菜单" > $null
        }
    }
}

function Invoke-UninstallTask {
    param([bool]$interactive = $true)
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "   TraeWorkCheckin - 卸载自动签到任务" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[处理中] 正在清理启动项与计划任务..." -ForegroundColor DarkGray

    $startupDir = Get-UserStartupDir
    $lnkPath = Join-Path $startupDir 'TraeWorkCheckin.lnk'
    $oldLnkPath = Join-Path $startupDir 'TraeWorkAutoCheckin.lnk'

    $removed = $false
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath -Force -ErrorAction SilentlyContinue
        $removed = $true
    }
    if (Test-Path $oldLnkPath) {
        Remove-Item $oldLnkPath -Force -ErrorAction SilentlyContinue
        $removed = $true
    }

    # 极速清理所有带有 TraeWork 字样的计划任务、每日任务与兜底重试任务（采用 schtasks，毫秒级响应）
    schtasks /Delete /TN 'TraeWorkCheckin_Daily' /F 2>$null | Out-Null
    schtasks /Delete /TN 'TraeWorkCheckin_Retry' /F 2>$null | Out-Null
    schtasks /Delete /TN 'TraeWorkCheckin' /F 2>$null | Out-Null
    schtasks /Delete /TN 'TraeWork每日签到' /F 2>$null | Out-Null
    schtasks /Delete /TN 'TraeWorkAutoCheckin' /F 2>$null | Out-Null

    Write-Host ""
    if ($removed) {
        Write-Host "[成功] 已成功移除开机启动快捷方式！" -ForegroundColor Green
    } else {
        Write-Host "[提示] 未在系统启动目录检测到已安装的快捷方式。" -ForegroundColor Yellow
    }
    Write-Host "[完成] 开机自启配置与所有 TraeWork 计划/重试任务已全部清理干净。" -ForegroundColor Green

    if ($interactive) {
        Write-Host ""
        Write-Host "----------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "请按任意键返回主菜单..." -ForegroundColor Yellow
        try {
            while ([Console]::KeyAvailable) { [Console]::ReadKey($true) > $null }
            if (-not [Console]::IsInputRedirected) {
                [Console]::ReadKey($true) > $null
            } else {
                Read-Host "按回车键返回主菜单" > $null
            }
        } catch {
            Read-Host "按回车键返回主菜单" > $null
        }
    }
}

function Invoke-RunCheckin {
    param([bool]$interactive = $true)
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "   TraeWorkCheckin - 立即测试执行签到" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[启动] 正在调用签到执行器..." -ForegroundColor Cyan
    Write-Host "----------------------------------------------------" -ForegroundColor DarkGray
    & (Join-Path $scriptDir "run_traework_checkin.cmd")
    Write-Host "----------------------------------------------------" -ForegroundColor DarkGray
    if ($interactive) {
        Write-Host ""
        Write-Host "请按任意键返回主菜单..." -ForegroundColor Yellow
        try {
            while ([Console]::KeyAvailable) { [Console]::ReadKey($true) > $null }
            if (-not [Console]::IsInputRedirected) {
                [Console]::ReadKey($true) > $null
            } else {
                Read-Host "按回车键返回主菜单" > $null
            }
        } catch {
            Read-Host "按回车键返回主菜单" > $null
        }
    }
}

# 处理命令行快速传参
$firstArg = $args[0]
if ($firstArg -in @('--install', '-i', 'install')) {
    Invoke-InstallTask -interactive $false
    exit 0
}
if ($firstArg -in @('--uninstall', '-u', 'uninstall')) {
    Invoke-UninstallTask -interactive $false
    exit 0
}
if ($firstArg -in @('--run', '-r', 'run')) {
    Invoke-RunCheckin -interactive $false
    exit 0
}

# 交互式菜单选项定义
$options = @(
    @{ Text = "安装双轨全自动签到 (开机登录静默自启 + 每日 00:00:30 定时触发)"; Action = "install" },
    @{ Text = "卸载所有自动任务 (彻底移除开机自启项与 TraeWork 定时/重试任务)"; Action = "uninstall" },
    @{ Text = "立即测试执行签到 (查看实时控制台输出与积分状态播报)"; Action = "run" },
    @{ Text = "退出管理程序"; Action = "exit" }
)

function Render-Menu {
    param([int]$curIndex)
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "      TraeWorkCheckin - 自动签到管理控制台" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  提示：使用键盘 [↑ / ↓] 键移动光标，按 [Enter] 确认选择" -ForegroundColor DarkGray
    Write-Host "        亦可直接按下对应数字键 [1 / 2 / 3 / 0] 快速选择" -ForegroundColor DarkGray
    Write-Host "----------------------------------------------------" -ForegroundColor DarkGray

    # 实时检测当前系统配置状态
    $startupDir = Get-UserStartupDir
    $lnkInstalled = Test-Path (Join-Path $startupDir 'TraeWorkCheckin.lnk')
    
    $dailyTask = schtasks /Query /TN 'TraeWorkCheckin_Daily' 2>$null
    $dailyInstalled = ($LASTEXITCODE -eq 0)

    Write-Host "当前防护：" -ForegroundColor Cyan -NoNewline
    if ($lnkInstalled) {
        Write-Host "开机自启 [已就绪]  " -ForegroundColor Green -NoNewline
    } else {
        Write-Host "开机自启 [未安装]  " -ForegroundColor DarkGray -NoNewline
    }
    if ($dailyInstalled) {
        Write-Host "00:00:30定时 [已就绪]  " -ForegroundColor Green -NoNewline
    } else {
        Write-Host "00:00:30定时 [未配置]  " -ForegroundColor DarkGray -NoNewline
    }
    Write-Host "原生通知 [支持]" -ForegroundColor Green
    Write-Host "----------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    for ($i = 0; $i -lt $options.Count; $i++) {
        $keyHint = if ($i -eq $options.Count - 1) { "0" } else { "$($i + 1)" }
        if ($i -eq $curIndex) {
            Write-Host " ▶ " -ForegroundColor Green -NoNewline
            Write-Host "[$keyHint] " -ForegroundColor Green -NoNewline
            Write-Host "$($options[$i].Text)" -ForegroundColor Green
        } else {
            Write-Host "   " -NoNewline
            Write-Host "[$keyHint] " -ForegroundColor DarkGray -NoNewline
            Write-Host "$($options[$i].Text)" -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Cyan
}

# 标准文本菜单降级（用于不支持 Console.ReadKey 的终端环境）
function Show-StandardMenu {
    while ($true) {
        Write-Host ""
        Write-Host "====================================================" -ForegroundColor Cyan
        Write-Host "      TraeWorkCheckin - 自动签到管理控制台" -ForegroundColor Cyan
        Write-Host "====================================================" -ForegroundColor Cyan
        for ($i = 0; $i -lt $options.Count; $i++) {
            $keyHint = if ($i -eq $options.Count - 1) { "0" } else { "$($i + 1)" }
            Write-Host "  [$keyHint] $($options[$i].Text)" -ForegroundColor Gray
        }
        Write-Host "----------------------------------------------------" -ForegroundColor DarkGray
        $choice = Read-Host "请输入数字选项 [1 / 2 / 3 / 0]"
        if ($null -eq $choice) {
            Write-Host "感谢使用，程序正在退出..." -ForegroundColor Cyan
            exit 0
        }
        switch ($choice.Trim()) {
            '1' { Invoke-InstallTask -interactive $true }
            '2' { Invoke-UninstallTask -interactive $true }
            '3' { Invoke-RunCheckin -interactive $true }
            '0' {
                Clear-Host
                Write-Host ""
                Write-Host "感谢使用，程序正在退出..." -ForegroundColor Cyan
                exit 0
            }
            'q' {
                Clear-Host
                Write-Host ""
                Write-Host "感谢使用，程序正在退出..." -ForegroundColor Cyan
                exit 0
            }
            default {
                Write-Host "[提示] 无效的选项，请输入 1、2、3 或 0。" -ForegroundColor Yellow
            }
        }
    }
}

# 检查当前终端是否支持原生 Console.ReadKey
$canUseReadKey = $false
try {
    if (-not [Console]::IsInputRedirected) {
        $canUseReadKey = $true
    }
} catch {
    $canUseReadKey = $false
}

if (-not $canUseReadKey) {
    Show-StandardMenu
    exit 0
}

# 交互式键盘监听循环
$selectedIndex = 0

while ($true) {
    Render-Menu -curIndex $selectedIndex
    try {
        $keyInfo = [Console]::ReadKey($true)
    } catch {
        # 若 ReadKey 发生异常，平滑降级为标准输入菜单
        Show-StandardMenu
        exit 0
    }

    $isEnter = ($keyInfo.Key -eq [ConsoleKey]::Enter -or $keyInfo.KeyChar -eq "`r" -or $keyInfo.KeyChar -eq "`n" -or $keyInfo.Key -eq [ConsoleKey]::Spacebar)

    if ($keyInfo.Key -eq [ConsoleKey]::UpArrow) {
        $selectedIndex = ($selectedIndex - 1 + $options.Count) % $options.Count
    }
    elseif ($keyInfo.Key -eq [ConsoleKey]::DownArrow) {
        $selectedIndex = ($selectedIndex + 1) % $options.Count
    }
    elseif ($isEnter) {
        $act = $options[$selectedIndex].Action
        if ($act -eq "install") { Invoke-InstallTask -interactive $true }
        elseif ($act -eq "uninstall") { Invoke-UninstallTask -interactive $true }
        elseif ($act -eq "run") { Invoke-RunCheckin -interactive $true }
        elseif ($act -eq "exit") {
            Clear-Host
            Write-Host ""
            Write-Host "感谢使用，程序正在退出..." -ForegroundColor Cyan
            exit 0
        }
    }
    elseif ($keyInfo.Key -eq [ConsoleKey]::D1 -or $keyInfo.Key -eq [ConsoleKey]::NumPad1 -or $keyInfo.KeyChar -eq '1') {
        Invoke-InstallTask -interactive $true
    }
    elseif ($keyInfo.Key -eq [ConsoleKey]::D2 -or $keyInfo.Key -eq [ConsoleKey]::NumPad2 -or $keyInfo.KeyChar -eq '2') {
        Invoke-UninstallTask -interactive $true
    }
    elseif ($keyInfo.Key -eq [ConsoleKey]::D3 -or $keyInfo.Key -eq [ConsoleKey]::NumPad3 -or $keyInfo.KeyChar -eq '3') {
        Invoke-RunCheckin -interactive $true
    }
    elseif ($keyInfo.Key -eq [ConsoleKey]::D0 -or $keyInfo.Key -eq [ConsoleKey]::NumPad0 -or $keyInfo.KeyChar -eq '0' -or $keyInfo.Key -eq [ConsoleKey]::Escape -or $keyInfo.KeyChar -eq 'q' -or $keyInfo.KeyChar -eq 'Q') {
        Clear-Host
        Write-Host ""
        Write-Host "感谢使用，程序正在退出..." -ForegroundColor Cyan
        exit 0
    }
}
