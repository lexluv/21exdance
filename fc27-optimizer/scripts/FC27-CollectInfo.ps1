#Requires -Version 5.1
<#
.SYNOPSIS
    Собирает максимум информации о ПК, Windows, игре и сети в один текстовый отчёт. Ничего не меняет.

.DESCRIPTION
    Сначала подробные данные (железо, драйверы, настройки, сбои, процессы, сетевая карта, трассировка),
    затем полная проверка из FC27-Check.ps1 (пинг, bufferbloat).
    Отчёт сохраняется на рабочий стол и копируется в буфер обмена. Имя пользователя, имя ПК,
    MAC-адреса, имя Wi-Fi сети и внешний IP в отчёт не попадают.
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$ExeName = 'FC27.exe',
    [switch]$NoLoadTest,
    [switch]$NoPause
)

. (Join-Path $PSScriptRoot 'FC27-Common.ps1')

$desktop = [Environment]::GetFolderPath('Desktop')
$reportPath = Join-Path $desktop ('FC27-info-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmm'))
$transcribing = $false
try { Start-Transcript -Path $reportPath -ErrorAction Stop | Out-Null; $transcribing = $true } catch { }

function Show-Table($Data) {
    if ($null -eq $Data) { return }
    $Data | Format-Table -AutoSize -Wrap | Out-String -Width 220 | ForEach-Object { $_.TrimEnd() } | Write-Host
}

function Show-Lines([string[]]$Lines) {
    foreach ($l in $Lines) { if ($l -and $l.Trim()) { Write-Host ('    ' + $l.TrimEnd()) } }
}

function Format-RegValue([string]$Path, [string]$Name) {
    $v = Get-RegValueInfo -Path $Path -Name $Name
    if ($v) { return [string]$v.Value }
    return '(нет)'
}

Write-Banner 'FC 27 Optimizer — сбор информации для диагностики (ничего не меняет)'
Write-Info 'Имя пользователя, имя ПК, MAC-адреса, имя Wi-Fi сети и внешний IP в отчёт не попадают.'
Write-Info 'Займёт 2–3 минуты. В конце попросим запустить тест скорости в браузере.'

# ------------------------------------------------------------------ Windows

Invoke-Step 'Windows' {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $uptime = (Get-Date) - $os.LastBootUpTime
    Write-Info ('{0} {1}, сборка {2}.{3}' -f $os.Caption, $cv.DisplayVersion, $os.BuildNumber, $cv.UBR)
    Write-Info ('Без перезагрузки: {0} д {1} ч' -f $uptime.Days, $uptime.Hours)
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        Write-Warn 'Windows ждёт перезагрузки после обновлений'
    }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    Write-Info ('Тип: {0} {1}' -f $cs.Manufacturer, $cs.Model)
}

# ------------------------------------------------------------------ Железо

Invoke-Step 'Процессор, плата, память' {
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    Write-Info ('CPU: {0}; {1} ядер / {2} потоков; базовая {3} МГц; загрузка сейчас {4}%' -f `
        $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.MaxClockSpeed, $cpu.LoadPercentage)
    $board = Get-CimInstance -ClassName Win32_BaseBoard | Select-Object -First 1
    $bios = Get-CimInstance -ClassName Win32_BIOS | Select-Object -First 1
    Write-Info ('Плата: {0} {1}' -f $board.Manufacturer, $board.Product)
    Write-Info ('BIOS: {0} от {1:dd.MM.yyyy}' -f $bios.SMBIOSBIOSVersion, $bios.ReleaseDate)

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-Info ('ОЗУ: всего {0:N1} ГБ, свободно сейчас {1:N1} ГБ' -f ($os.TotalVisibleMemorySize / 1MB), ($os.FreePhysicalMemory / 1MB))
    Show-Table (Get-CimInstance -ClassName Win32_PhysicalMemory | Select-Object `
        @{ n = 'Слот'; e = { $_.DeviceLocator } },
        @{ n = 'ГБ'; e = { [math]::Round($_.Capacity / 1GB) } },
        @{ n = 'Паспорт, МГц'; e = { $_.Speed } },
        @{ n = 'Сейчас, МГц'; e = { $_.ConfiguredClockSpeed } },
        @{ n = 'Производитель'; e = { ([string]$_.Manufacturer).Trim() } },
        @{ n = 'Модель'; e = { ([string]$_.PartNumber).Trim() } })

    $pf = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue)
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $pfText = ($pf | ForEach-Object { '{0} {1} МБ' -f $_.Name, $_.AllocatedBaseSize }) -join ', '
    if (-not $pfText) { $pfText = 'нет' }
    Write-Info ('Файл подкачки: {0}; автоматически: {1}' -f $pfText, $cs.AutomaticManagedPagefile)
}

Invoke-Step 'Видеокарта и мониторы' {
    Show-Table (Get-CimInstance -ClassName Win32_VideoController | Select-Object `
        @{ n = 'GPU'; e = { $_.Name } },
        @{ n = 'Драйвер'; e = { $_.DriverVersion } },
        @{ n = 'Дата'; e = { if ($_.DriverDate) { $_.DriverDate.ToString('dd.MM.yyyy') } } },
        @{ n = 'Разрешение'; e = { if ($_.CurrentHorizontalResolution) { '{0}x{1}' -f $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution } } },
        @{ n = 'Гц'; e = { $_.CurrentRefreshRate } })

    $smi = Get-NvidiaSmiPath
    if ($smi) {
        Write-Info 'nvidia-smi:'
        $fields = 'name,driver_version,vbios_version,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,' +
                  'pcie.link.width.max,temperature.gpu,fan.speed,power.draw,power.limit,clocks.gr,clocks.max.gr,' +
                  'clocks.mem,utilization.gpu,memory.used,memory.total,pstate'
        Show-Lines @(& $smi "--query-gpu=$fields" '--format=csv' 2>&1 | ForEach-Object { [string]$_ })
    }

    try {
        foreach ($m in @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorID -ErrorAction Stop)) {
            $name = -join ($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
            $maker = -join ($m.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
            Write-Info ('Монитор: {0} {1}' -f $maker, $name)
        }
    } catch { }
}

Invoke-Step 'Диски' {
    $inv = @(Get-DiskInventory)
    if ($inv.Count -gt 0 -and $inv[0]) { Show-Table $inv } else { Write-Warn 'Windows не ответила на запрос о дисках за 25 секунд' }
    Show-Table ([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq [IO.DriveType]::Fixed } | Select-Object `
        @{ n = 'Том'; e = { $_.Name } },
        @{ n = 'ФС'; e = { $_.DriveFormat } },
        @{ n = 'Всего, ГБ'; e = { [math]::Round($_.TotalSize / 1GB) } },
        @{ n = 'Свободно, ГБ'; e = { [math]::Round($_.AvailableFreeSpace / 1GB) } })
}

# ------------------------------------------------------------------ Настройки Windows

Invoke-Step 'Питание и игровые настройки Windows' {
    Write-Info 'Планы питания (* — активный):'
    Show-Lines @((Invoke-PowerCfg @('/list')).Output -split "`n" | Where-Object { $_ -match '[0-9a-f]{8}-' })

    $rows = @(
        @('Игровой режим', 'HKCU:\Software\Microsoft\GameBar', 'AutoGameModeEnabled'),
        @('Game Bar по кнопке Xbox', 'HKCU:\Software\Microsoft\GameBar', 'UseNexusForGameBarEnabled'),
        @('Запись Game Bar', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled'),
        @('Game DVR', 'HKCU:\System\GameConfigStore', 'GameDVR_Enabled'),
        @('HAGS (2 = вкл)', 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 'HwSchMode'),
        @('DirectX: глобальные настройки', 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences', 'DirectXUserGlobalSettings'),
        @('NetworkThrottlingIndex', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'NetworkThrottlingIndex'),
        @('SystemResponsiveness', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'SystemResponsiveness'),
        @('MMCSS Games: Priority', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Priority'),
        @('MMCSS Games: GPU Priority', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'GPU Priority'),
        @('Раздача обновлений (DO policy)', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization', 'DODownloadMode'),
        @('Раздача обновлений (польз.)', 'Registry::HKEY_USERS\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings', 'DownloadMode'),
        @('Прозрачность интерфейса', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'EnableTransparency'),
        @('Визуальные эффекты', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects', 'VisualFXSetting')
    )
    Show-Table ($rows | ForEach-Object { [pscustomobject]@{ 'Параметр' = $_[0]; 'Значение' = (Format-RegValue $_[1] $_[2]) } })

    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        Write-Info ('VBS: {0} (2 = работает); целостность памяти (HVCI): {1}' -f `
            $dg.VirtualizationBasedSecurityStatus, (@($dg.SecurityServicesRunning) -contains 2))
    } catch { }
    try {
        $av = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName })
        Write-Info ('Антивирус: ' + ($av -join ', '))
    } catch { }
    if (Test-Path -LiteralPath $script:BackupFile) {
        $n = @((Get-Content -LiteralPath $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json).Entries).Count
        Write-Info ('FC27 Optimizer применён, записей в резервной копии: {0}' -f $n)
    } else {
        Write-Info 'FC27 Optimizer ещё не применялся'
    }
}

# ------------------------------------------------------------------ Игра

Invoke-Step 'Игра' {
    $exe = Resolve-GameExe -GamePath $GamePath -ExeName $ExeName
    if ($exe) {
        $vi = (Get-Item -LiteralPath $exe).VersionInfo
        Write-Info ('Путь: {0}' -f $exe)
        Write-Info ('Версия exe: {0}' -f $vi.FileVersion)
        $name = Split-Path $exe -Leaf
        $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $name + '\PerfOptions'
        Write-Info ('Приоритет CPU (IFEO, 3 = высокий): ' + (Format-RegValue $ifeo 'CpuPriorityClass'))
        Write-Info ('Выбор GPU: ' + (Format-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $exe))
        Write-Info ('Флаги совместимости (польз.): ' + (Format-RegValue 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' $exe))
        Write-Info ('Флаги совместимости (все): ' + (Format-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' $exe))
    } else {
        Write-Warn ($ExeName + ' не найден')
    }

    $ea = Join-Path $env:ProgramFiles 'Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe'
    if (Test-Path -LiteralPath $ea) { Write-Info ('EA app: ' + (Get-Item -LiteralPath $ea).VersionInfo.ProductVersion) }

    # Настройки графики игры: Документы\FC 27\*.ini (fcsetup.ini и т. п.)
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $pattern = Get-GameNamePattern $ExeName
    $dirs = @(Get-ChildItem -LiteralPath $docs -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern })
    foreach ($d in $dirs) {
        foreach ($ini in @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.ini' -File -ErrorAction SilentlyContinue)) {
            if ($ini.Length -gt 16KB) { continue }
            Write-Info ('Файл настроек игры: Документы\{0}\{1}' -f $d.Name, $ini.Name)
            Show-Lines @(Get-Content -LiteralPath $ini.FullName -ErrorAction SilentlyContinue)
        }
    }
    if ($dirs.Count -eq 0) { Write-Info 'Папка настроек игры в «Документах» не найдена' }
}

Invoke-Step 'Сбои за последние 30 дней' {
    $since = (Get-Date).AddDays(-30)
    $game = [IO.Path]::GetFileNameWithoutExtension($ExeName)
    try {
        $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; StartTime = $since } -ErrorAction Stop |
            Where-Object { [string]$_.Properties[0].Value -match $game })
        Write-Info ('Вылеты {0}: {1}' -f $ExeName, $crashes.Count)
        foreach ($c in ($crashes | Select-Object -First 5)) {
            Write-Info ('  {0:dd.MM HH:mm} модуль {1}, код {2}' -f $c.TimeCreated, $c.Properties[3].Value, $c.Properties[6].Value)
        }
    } catch { Write-Info 'Вылеты игры: 0' }

    $checks = @(
        @('Сбросы видеодрайвера (TDR)', @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $since }),
        @('Ошибки драйвера NVIDIA', @{ LogName = 'System'; ProviderName = 'nvlddmkm'; StartTime = $since }),
        @('Аппаратные ошибки WHEA', @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since }),
        @('Внезапные отключения питания', @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since })
    )
    foreach ($c in $checks) {
        $n = 0
        try { $n = @(Get-WinEvent -FilterHashtable $c[1] -ErrorAction Stop).Count } catch { }
        if ($n -gt 0) { Write-Warn ('{0}: {1}' -f $c[0], $n) } else { Write-Info ('{0}: 0' -f $c[0]) }
    }
}

# ------------------------------------------------------------------ Программы

Invoke-Step 'Автозагрузка' {
    Show-Table (Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object `
        @{ n = 'Программа'; e = { $_.Name } },
        @{ n = 'Файл'; e = { [regex]::Match([string]$_.Command, '[^\\"]+\.exe', 'IgnoreCase').Value } },
        @{ n = 'Где'; e = { $_.Location } })
}

Invoke-Step 'Процессы: кто грузит CPU и память (замер 3 с)' {
    $before = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { if ($null -ne $p.CPU) { $before[$p.Id] = $p.CPU } }
    Start-Sleep -Seconds 3
    $cores = [Environment]::ProcessorCount
    $procs = @(Get-Process -ErrorAction SilentlyContinue)
    Write-Info ('Всего процессов: {0}' -f $procs.Count)
    Show-Table ($procs | Where-Object { $before.ContainsKey($_.Id) -and $null -ne $_.CPU } |
        Select-Object @{ n = 'Процесс'; e = { $_.ProcessName } },
                      @{ n = 'CPU, %'; e = { [math]::Round(($_.CPU - $before[$_.Id]) * 100 / 3 / $cores, 1) } } |
        Sort-Object 'CPU, %' -Descending | Select-Object -First 10)
    Show-Table ($procs | Group-Object ProcessName | Select-Object `
        @{ n = 'Процесс'; e = { $_.Name } },
        @{ n = 'Копий'; e = { $_.Count } },
        @{ n = 'ОЗУ, МБ'; e = { [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB) } } |
        Sort-Object 'ОЗУ, МБ' -Descending | Select-Object -First 15)
}

# ------------------------------------------------------------------ Сеть

Invoke-Step 'Сеть: адаптеры' {
    Show-Table (Get-NetAdapter -IncludeHidden:$false -ErrorAction SilentlyContinue | Select-Object `
        @{ n = 'Имя'; e = { $_.Name } },
        @{ n = 'Устройство'; e = { $_.InterfaceDescription } },
        @{ n = 'Статус'; e = { $_.Status } },
        @{ n = 'Скорость'; e = { $_.LinkSpeed } },
        @{ n = 'Физ.'; e = { $_.HardwareInterface } },
        @{ n = 'Драйвер'; e = { $_.DriverVersion } },
        @{ n = 'Дата драйвера'; e = { $_.DriverDate } })

    $inet = Get-InternetRoute
    if ($inet -and $inet.Adapter) {
        Write-Info ('В интернет через: {0} ({1})' -f $inet.Adapter.Name, $inet.Adapter.InterfaceDescription)
        $ip = Get-NetIPAddress -InterfaceIndex $inet.Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        foreach ($pair in @(@('IPv4 ПК', $ip.IPAddress), @('Шлюз', $inet.Gateway))) {
            $v = [string]$pair[1]
            if ($v -and -not (Test-PrivateIPv4 $v)) { $v = 'публичный (скрыт) — ПК подключён к провайдеру напрямую, без роутера?' }
            Write-Info ('{0}: {1}' -f $pair[0], $v)
        }
        if ($ip) { Write-Info ('Маска: /{0}, источник: {1}' -f $ip.PrefixLength, $ip.PrefixOrigin) }
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $inet.Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        Write-Info ('DNS: ' + ($dns -join ', '))
        $v6 = @(Get-NetIPAddress -InterfaceIndex $inet.Adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -in @('RouterAdvertisement', 'Dhcp') })
        Write-Info ('Глобальный IPv6: ' + $(if ($v6.Count -gt 0) { 'есть' } else { 'нет' }))
        $mtu = (Get-NetIPInterface -InterfaceIndex $inet.Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).NlMtu
        Write-Info ('MTU: ' + $mtu)
    }

    $proxy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($proxy -and $proxy.ProxyEnable -eq 1) {
        $srv = [string]$proxy.ProxyServer
        if ($srv -notmatch '127\.0\.0\.1|localhost') { $srv = '(внешний, скрыт)' }
        Write-Warn ('Включён системный прокси: {0} — обычно это VPN-клиент' -f $srv)
    }
}

Invoke-Step 'Сеть: настройки сетевой карты' {
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        Write-Host ('  {0} — {1}' -f $a.Name, $a.InterfaceDescription) -ForegroundColor White
        Show-Table ($a | Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue | Select-Object `
            @{ n = 'Параметр'; e = { $_.DisplayName } },
            @{ n = 'Значение'; e = { $_.DisplayValue } },
            @{ n = 'Ключ'; e = { $_.RegistryKeyword } },
            @{ n = 'Код'; e = { $_.RegistryValue -join ',' } })
        $classKey = Get-AdapterClassKey $a.InterfaceGuid
        if ($classKey) { Write-Info ('PnPCapabilities (24 = не отключать ради экономии): ' + (Format-RegValue $classKey 'PnPCapabilities')) }
        $pm = $a | Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue
        if ($pm) {
            Write-Info ('Энергосбережение: AllowComputerToTurnOffDevice={0}, SelectiveSuspend={1}, DeviceSleepOnDisconnect={2}' -f `
                $pm.AllowComputerToTurnOffDevice, $pm.SelectiveSuspend, $pm.DeviceSleepOnDisconnect)
        }
        $ifKey = $script:TcpipIfKey + '\' + $a.InterfaceGuid
        Write-Info ('TcpAckFrequency={0}, TCPNoDelay={1}' -f (Format-RegValue $ifKey 'TcpAckFrequency'), (Format-RegValue $ifKey 'TCPNoDelay'))
        $rss = $a | Get-NetAdapterRss -ErrorAction SilentlyContinue
        if ($rss) { Write-Info ('RSS: {0}' -f $rss.Enabled) }
    }
}

Invoke-Step 'Сеть: TCP и QoS' {
    Show-Lines @(& netsh.exe int tcp show global 2>$null | ForEach-Object { [string]$_ })
    $qos = @(Get-NetQosPolicy -ErrorAction SilentlyContinue)
    if ($qos.Count -gt 0) {
        Show-Table ($qos | Select-Object Name, AppPathName, DSCPAction, ThrottleRateActionBitsPerSecond)
    } else {
        Write-Info 'QoS-политик нет'
    }
}

Invoke-Step 'Сеть: Wi-Fi' {
    $wlan = @(& netsh.exe wlan show interfaces 2>$null | ForEach-Object { [string]$_ })
    if (-not ($wlan -match ':')) { Write-Info 'Wi-Fi не используется'; return }
    # Без имени сети, BSSID, MAC и профиля.
    $private = 'SSID|BSSID|Physical address|Физический адрес|Profile|Профиль|GUID|^\s*(Name|Имя)\s*:'
    Show-Lines @($wlan | Where-Object { $_ -notmatch $private })
    Write-Info 'Драйвер Wi-Fi:'
    $drv = @(& netsh.exe wlan show drivers 2>$null | ForEach-Object { [string]$_ })
    Show-Lines @($drv | Where-Object { $_ -match 'Driver|Драйвер|Vendor|Поставщик|Version|Версия|Date|Дата|Radio|радио|Band|Диапазон|802\.11' } |
        Select-Object -First 20)
}

Invoke-Step 'Сеть: трассировка до 8.8.8.8 (до 40 с)' {
    Show-Lines @(& tracert.exe -d -h 15 -w 700 8.8.8.8 2>$null | ForEach-Object { [string]$_ })
}

Invoke-Step 'Сеть: пинг до европейских дата-центров (по 5 запросов)' {
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $hosts = [ordered]@{ 'Германия (speed.hetzner.de)' = 'speed.hetzner.de'; 'Франция (ping.online.net)' = 'ping.online.net' }
    foreach ($h in $hosts.GetEnumerator()) {
        $ok = @()
        for ($i = 0; $i -lt 5; $i++) {
            try {
                $r = $pinger.Send($h.Value, 1500)
                if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $ok += [int]$r.RoundtripTime }
            } catch { }
            Start-Sleep -Milliseconds 200
        }
        if ($ok.Count -gt 0) {
            Write-Info ('{0}: мин {1} / сред {2} мс, ответов {3} из 5' -f $h.Key, ($ok | Measure-Object -Minimum).Minimum,
                [math]::Round(($ok | Measure-Object -Average).Average), $ok.Count)
        } else {
            Write-Info ('{0}: нет ответа' -f $h.Key)
        }
    }
}

# ------------------------------------------------------------------ Проверка с пингом и bufferbloat

$checkArgs = @{ ExeName = $ExeName; NoTranscript = $true; NoPause = $true }
if ($GamePath) { $checkArgs.GamePath = $GamePath }
if ($NoLoadTest) { $checkArgs.NoLoadTest = $true }
& (Join-Path $PSScriptRoot 'FC27-Check.ps1') @checkArgs

# ------------------------------------------------------------------ Отчёт

if ($transcribing) {
    Stop-Transcript | Out-Null
    $text = Protect-ReportFile $reportPath
    $copied = $false
    try { Set-Clipboard -Value $text -ErrorAction Stop; $copied = $true } catch { }
    Write-Host ''
    Write-Banner 'Готово'
    Write-Ok ('Отчёт сохранён на рабочий стол: ' + (Split-Path $reportPath -Leaf))
    if ($copied) { Write-Ok 'Отчёт уже скопирован — просто вставьте его в чат (Ctrl+V).' }
    else { Write-Info 'Откройте файл, выделите всё (Ctrl+A), скопируйте и вставьте в чат.' }
    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $reportPath) -ErrorAction SilentlyContinue
}
Wait-Exit -NoPause:$NoPause
