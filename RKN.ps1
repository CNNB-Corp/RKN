#Requires -Version 5.1

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:Root 'config/rkn.settings.json'
$script:StatePath = Join-Path $script:Root 'config/rkn.state.json'

function Initialize-Environment {
    $logDir = Join-Path $script:Root 'logs'
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $script:ConfigPath)) {
        throw "Не найден файл настроек: $script:ConfigPath"
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $config = Get-Config
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp][$Level] $Message"
    $logPath = Join-Path $script:Root $config.Advanced.LogPath
    $logDir = Split-Path -Parent $logPath
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path $logPath -Value $line
}

function Get-Config {
    return Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json
}

function Save-Config {
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    $Config | ConvertTo-Json -Depth 6 | Set-Content -Path $script:ConfigPath
}

function Save-State {
    param(
        [Parameter(Mandatory)]
        [object]$State
    )
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $script:StatePath
}

function Get-State {
    if (-not (Test-Path $script:StatePath)) {
        return $null
    }
    return Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
}

function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Select-Adapters {
    param(
        [Parameter(Mandatory)]
        [string]$Pattern
    )
    Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and $_.Name -match $Pattern
    }
}

function Get-AdapterSnapshot {
    param(
        [Parameter(Mandatory)]
        [object[]]$Adapters
    )

    $previous = @()
    foreach ($adapter in $Adapters) {
        $current = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4
        $previous += [PSCustomObject]@{
            InterfaceIndex = $adapter.InterfaceIndex
            InterfaceAlias = $adapter.Name
            Servers = $current.ServerAddresses
        }
    }
    $previous
}

function Test-DnsCandidate {
    param(
        [Parameter(Mandatory)]
        [object]$Candidate,
        [Parameter(Mandatory)]
        [string[]]$TargetDomains,
        [int]$Attempts = 2
    )

    $successCount = 0
    $totalDuration = 0

    foreach ($domain in $TargetDomains) {
        for ($i = 0; $i -lt $Attempts; $i += 1) {
            $duration = Measure-Command {
                try {
                    Resolve-DnsName -Name $domain -Server $Candidate.Servers[0] -Type A -ErrorAction Stop | Out-Null
                    $successCount += 1
                } catch {
                    Write-Log "DNS ${$Candidate.Name} не ответил для $domain." 'WARN'
                }
            }
            $totalDuration += $duration.TotalMilliseconds
        }
    }

    $totalChecks = $TargetDomains.Count * $Attempts
    $successRate = if ($totalChecks -gt 0) { $successCount / $totalChecks } else { 0 }

    [PSCustomObject]@{
        Name = $Candidate.Name
        Servers = $Candidate.Servers
        SuccessRate = $successRate
        AvgLatencyMs = if ($totalChecks -gt 0) { [math]::Round($totalDuration / $totalChecks, 2) } else { 0 }
    }
}

function Rank-DnsCandidates {
    $config = Get-Config
    $results = foreach ($candidate in $config.Advanced.DnsCandidates) {
        Test-DnsCandidate -Candidate $candidate -TargetDomains $config.Basic.TargetDomains -Attempts $config.Advanced.TestAttempts
    }

    $results | Sort-Object -Property @{Expression = 'SuccessRate'; Descending = $true}, @{Expression = 'AvgLatencyMs'; Descending = $false}
}

function Test-HttpEndpoint {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [int]$TimeoutSec = 6
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -UseBasicParsing -TimeoutSec $TimeoutSec
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
            return $true
        }
    } catch {
        Write-Log "HTTP проверка не прошла для $Url. $_" 'WARN'
    }

    return $false
}

function Test-Connectivity {
    param(
        [Parameter(Mandatory)]
        [string[]]$Urls,
        [int]$TimeoutSec = 6
    )

    foreach ($url in $Urls) {
        if (-not (Test-HttpEndpoint -Url $url -TimeoutSec $TimeoutSec)) {
            return $false
        }
    }

    return $true
}

function Apply-DnsConfiguration {
    param(
        [Parameter(Mandatory)]
        [object]$Selected,
        [Parameter(Mandatory)]
        [object[]]$Adapters
    )

    foreach ($adapter in $Adapters) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $Selected.Servers
        Write-Log "Применены DNS $($Selected.Name) для $($adapter.Name)."
    }
}

function Restore-DnsConfiguration {
    param(
        [Parameter(Mandatory)]
        [object[]]$Snapshot
    )

    foreach ($entry in $Snapshot) {
        if ($null -eq $entry.Servers -or $entry.Servers.Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceIndex $entry.InterfaceIndex -ResetServerAddresses
            Write-Log "DNS сброшены в DHCP для $($entry.InterfaceAlias)."
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $entry.InterfaceIndex -ServerAddresses $entry.Servers
            Write-Log "DNS восстановлены для $($entry.InterfaceAlias)."
        }
    }
}

function Show-Status {
    $state = Get-State
    if ($state) {
        Write-Host "Активно: $($state.Selected.Name) | Применено: $($state.AppliedAt)"
    } else {
        Write-Host 'RKN не активен.'
    }

    $config = Get-Config
    $adapters = Select-Adapters -Pattern $config.Basic.AdapterPattern

    foreach ($adapter in $adapters) {
        $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4
        Write-Host "[$($adapter.Name)] DNS: $($dns.ServerAddresses -join ', ')"
    }
}

function Prompt-BasicSettings {
    $config = Get-Config
    Write-Host 'Введите список доменов через запятую (Enter для пропуска):'
    $domainsInput = Read-Host
    if ($domainsInput) {
        $config.Basic.TargetDomains = $domainsInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    Write-Host "Шаблон адаптеров (текущий: $($config.Basic.AdapterPattern))"
    $adapterInput = Read-Host
    if ($adapterInput) {
        $config.Basic.AdapterPattern = $adapterInput
    }

    Save-Config -Config $config
    Write-Host 'Базовые настройки сохранены.'
}

function Open-AdvancedSettings {
    Write-Host 'Открываю файл настроек для продвинутого режима...'
    Start-Process -FilePath 'notepad.exe' -ArgumentList $script:ConfigPath -Wait
}

function Show-Header {
    Clear-Host
    Write-Host '====================================='
    Write-Host '          RKN (Zapret-like)          '
    Write-Host '====================================='
}

function Show-Menu {
    Write-Host '1. Запустить RKN'
    Write-Host '2. Остановить RKN'
    Write-Host '3. Статус'
    Write-Host '4. Базовые настройки'
    Write-Host '5. Гибкие настройки'
    Write-Host '0. Выход'
}

function Start-Rkn {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Для применения DNS нужны права администратора.'
        return
    }

    if (Get-State) {
        Write-Host 'RKN уже активен. Сначала остановите текущую сессию.'
        return
    }

    $config = Get-Config
    $adapters = Select-Adapters -Pattern $config.Basic.AdapterPattern
    if (-not $adapters) {
        Write-Host 'Не найдены подходящие сетевые адаптеры.'
        return
    }

    $snapshot = Get-AdapterSnapshot -Adapters $adapters
    $rankedCandidates = Rank-DnsCandidates
    if (-not $rankedCandidates) {
        Write-Host 'Список DNS-кандидатов пуст. Проверьте настройки.'
        return
    }

    Write-Host 'Подбираю рабочую инфраструктуру...'
    foreach ($candidate in $rankedCandidates) {
        Write-Host "Проверка: $($candidate.Name) ($($candidate.Servers -join ', '))"
        Apply-DnsConfiguration -Selected $candidate -Adapters $adapters
        Start-Sleep -Seconds 1

        $isReachable = Test-Connectivity -Urls $config.Advanced.HttpTestUrls -TimeoutSec $config.Advanced.HttpTimeoutSec
        if ($isReachable) {
            Save-State -State ([PSCustomObject]@{
                Selected = $candidate
                Previous = $snapshot
                AppliedAt = (Get-Date)
            })
            Write-Host "Выбрано: $($candidate.Name) ($($candidate.Servers -join ', '))"
            Write-Host 'RKN запущен.'
            return
        }

        Write-Log "Кандидат $($candidate.Name) не прошел HTTP-проверку." 'WARN'
        Restore-DnsConfiguration -Snapshot $snapshot
        Start-Sleep -Seconds $config.Advanced.RetryDelaySec
    }

    Write-Host 'Не удалось подобрать рабочую инфраструктуру. Проверьте сеть и список DNS.'
}

function Stop-Rkn {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Для восстановления DNS нужны права администратора.'
        return
    }

    $state = Get-State
    if (-not $state) {
        Write-Host 'Нет сохраненного состояния. Нечего выключать.'
        return
    }

    Restore-DnsConfiguration -Snapshot $state.Previous
    Remove-Item -Path $script:StatePath -Force
    Write-Host 'RKN остановлен.'
}

Initialize-Environment

while ($true) {
    Show-Header
    Show-Menu

    $choice = Read-Host 'Выберите действие'
    switch ($choice) {
        '1' {
            Start-Rkn
            Read-Host 'Нажмите Enter для продолжения'
        }
        '2' {
            Stop-Rkn
            Read-Host 'Нажмите Enter для продолжения'
        }
        '3' {
            Show-Status
            Read-Host 'Нажмите Enter для продолжения'
        }
        '4' {
            Prompt-BasicSettings
            Read-Host 'Нажмите Enter для продолжения'
        }
        '5' {
            Open-AdvancedSettings
        }
        '0' { break }
        default {
            Write-Host 'Неизвестная команда.'
            Start-Sleep -Seconds 1
        }
    }
}
