#Requires -Version 5.1
<#
.SYNOPSIS
    Диагностика ПК и интернета для EA SPORTS FC 27. Ничего не меняет.

.DESCRIPTION
    Проверяет железо и настройки Windows, фоновые программы, VPN, Wi-Fi/кабель,
    измеряет пинг, джиттер и потери до роутера и интернета, а также рост пинга
    под нагрузкой (bufferbloat). Отчёт сохраняется на рабочий стол.

.PARAMETER Seconds
    Длительность замера пинга в покое, секунд (по умолчанию 20).

.PARAMETER NoLoadTest
    Не проводить тест под нагрузкой.
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$ExeName = 'FC27.exe',
    [ValidateRange(5, 300)] [int]$Seconds = 20,
    [switch]$NoLoadTest,
    [switch]$NoPause
)

. (Join-Path $PSScriptRoot 'FC27-Common.ps1')

$desktop = [Environment]::GetFolderPath('Desktop')
$reportPath = Join-Path $desktop ('FC27-check-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmm'))
$transcribing = $false
try { Start-Transcript -Path $reportPath -ErrorAction Stop | Out-Null; $transcribing = $true } catch { }

Write-Banner 'FC 27 Optimizer — диагностика ПК и интернета (ничего не меняет)'

# ------------------------------------------------------------------ Железо

Invoke-Step 'Система' {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-Info ('{0} (сборка {1})' -f $os.Caption, $os.BuildNumber)

    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    Write-Info ('Процессор: {0} — {1} ядер / {2} потоков' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)

    $mem = @(Get-CimInstance -ClassName Win32_PhysicalMemory)
    $totalGb = [math]::Round((($mem | Measure-Object -Property Capacity -Sum).Sum) / 1GB)
    $speed = ($mem | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } |
        Measure-Object -Maximum).Maximum
    $type = ($mem | Select-Object -First 1).SMBIOSMemoryType
    $typeName = switch ($type) { 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } 29 { 'LPDDR3' } 30 { 'LPDDR4' } 35 { 'LPDDR5' } default { 'RAM' } }
    Write-Info ('Память: {0} ГБ {1}, модулей: {2}, частота: {3} МГц' -f $totalGb, $typeName, $mem.Count, $speed)
    if ($totalGb -lt 16) { Write-Warn 'Меньше 16 ГБ ОЗУ: перед игрой закрывайте браузер и лишние программы.' }
    if ($mem.Count -eq 1 -and ($typeName -eq 'DDR4' -or $typeName -eq 'DDR5')) {
        Write-Warn 'Одна планка памяти = одноканальный режим. Вторая такая же планка заметно поднимет FPS и уберёт фризы.'
    }
    if (($typeName -eq 'DDR4' -and $speed -le 2666) -or ($typeName -eq 'DDR5' -and $speed -le 4800)) {
        Write-Warn ('Память на базовой частоте {0} МГц. Если планки рассчитаны на большее — включите XMP/EXPO в BIOS.' -f $speed)
    }

    foreach ($g in @(Get-CimInstance -ClassName Win32_VideoController)) {
        if ($g.Name -match 'Microsoft Basic Display') {
            Write-Bad 'Драйвер видеокарты НЕ установлен (Microsoft Basic Display Adapter)! Установите его с сайта NVIDIA/AMD/Intel.'
            continue
        }
        $line = 'Видеокарта: {0}, драйвер {1}' -f $g.Name, $g.DriverVersion
        if ($g.DriverDate) {
            $age = [int]((Get-Date) - $g.DriverDate).TotalDays
            $line += (' от {0:dd.MM.yyyy}' -f $g.DriverDate)
            Write-Info $line
            if ($age -gt 120) { Write-Warn ('Драйверу {0} дн. Поставьте свежий — новые версии содержат оптимизации под новые игры.' -f $age) }
        } else {
            Write-Info $line
        }
        if ($g.CurrentRefreshRate) { Write-Info ('Частота обновления экрана сейчас: {0} Гц' -f $g.CurrentRefreshRate) }
    }
}

# ------------------------------------------------------------------ Настройки Windows

Invoke-Step 'Настройки Windows' {
    $plan = Get-ActivePowerPlan
    if ($plan) {
        if ($plan.Guid -eq $script:PlanGuid) { Write-Ok ('План питания: ' + $plan.Name) }
        elseif ($plan.Guid -eq $script:PlanBalanced) { Write-Warn ('План питания: {0} — для игры лучше «FC27 Max Performance» (2_Optimize.bat)' -f $plan.Name) }
        else { Write-Info ('План питания: ' + $plan.Name) }
    }

    $gm = Get-RegValueInfo 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    if ($gm -and [int]$gm.Value -eq 0) { Write-Warn 'Игровой режим Windows выключен' } else { Write-Ok 'Игровой режим Windows включён' }

    $dvr = Get-RegValueInfo 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'
    if ($dvr -and [int]$dvr.Value -eq 0) { Write-Ok 'Фоновая запись Xbox Game Bar выключена' }
    else { Write-Warn 'Запись Xbox Game Bar может быть включена (съедает ресурсы) — исправит 2_Optimize.bat' }

    $hags = Get-RegValueInfo 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    if ($hags -and [int]$hags.Value -eq 2) { Write-Info 'Аппаратное планирование GPU (HAGS): включено' }
    else { Write-Info 'Аппаратное планирование GPU (HAGS): выключено — см. README, раздел «Видеокарта»' }

    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        if (@($dg.SecurityServicesRunning) -contains 2) {
            Write-Info 'Целостность памяти (Memory Integrity) включена: безопасно, но может стоить несколько % FPS на старых CPU.'
        }
    } catch { }

    if (Test-Path -LiteralPath $script:BackupFile) { Write-Ok 'Оптимизация FC27 Optimizer применена' }
    else { Write-Info 'Оптимизация FC27 Optimizer ещё не применялась (2_Optimize.bat)' }
}

# ------------------------------------------------------------------ Игра

Invoke-Step 'Игра' {
    $exe = Resolve-GameExe -GamePath $GamePath -ExeName $ExeName
    if (-not $exe) {
        Write-Warn ($ExeName + ' не найден автоматически (это нормально, если игра в нестандартной папке).')
        return
    }
    Write-Ok ('Найдена: ' + $exe)
    $letter = $exe.Substring(0, 1)
    $drive = New-Object IO.DriveInfo ($letter)
    $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB)
    if ($freeGb -lt 20) { Write-Warn ('На диске {0}: свободно {1} ГБ — мало для обновлений и кэша шейдеров' -f $letter, $freeGb) }
    else { Write-Info ('На диске {0}: свободно {1} ГБ' -f $letter, $freeGb) }
    try {
        $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1
        if ($disk.MediaType -eq 'HDD') { Write-Bad 'Игра стоит на HDD — перенесите на SSD: исчезнут долгие загрузки и подтормаживания.' }
        elseif ($disk.MediaType -eq 'SSD') { Write-Ok 'Игра стоит на SSD' }
    } catch { }
}

# ------------------------------------------------------------------ Фоновые программы

Invoke-Step 'Фоновые программы, которые мешают игре' {
    $hints = [ordered]@{
        'qbittorrent|utorrent|bittorrent|transmission-qt|tixati|deluge|biglybt|mediaget' = 'Торрент-клиент — главный враг пинга. Закройте полностью (и из трея).'
        'fdm|idman'                              = 'Менеджер загрузок — не качайте во время матча.'
        'onedrive|dropbox|googledrivefs|yandexdisk' = 'Облачная синхронизация — поставьте на паузу во время игры.'
        'steam$|steamwebhelper'                  = 'Steam — проверьте, что не идут загрузки/обновления игр.'
        'epicgameslauncher|battle\.net|upc$'     = 'Другой лаунчер — может качать обновления в фоне.'
        'obs64|obs32|streamlabs'                 = 'OBS/стрим-софт — нагружает ПК и канал, если идёт запись или стрим.'
        '^discord$'                              = 'Discord — выключите «Оверлей в игре» (Настройки → Оверлей).'
    }
    $names = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
    $any = $false
    foreach ($h in $hints.GetEnumerator()) {
        $hit = @($names | Where-Object { $_ -match ('^(' + $h.Key + ')') })
        if ($hit.Count -gt 0) {
            Write-Warn ('{0}: {1}' -f ($hit -join ', '), $h.Value)
            $any = $true
        }
    }
    if (-not $any) { Write-Ok 'Явных «пожирателей» канала и ресурсов не найдено' }
}

# ------------------------------------------------------------------ Подключение

$script:Gateway = $null
$script:IsWifi = $false
Invoke-Step 'Подключение к интернету' {
    $inet = Get-InternetRoute
    if (-not $inet -or -not $inet.Adapter) { Write-Bad 'Не удалось определить подключение к интернету'; return }
    $a = $inet.Adapter
    $script:Gateway = $inet.Gateway
    $script:IsWifi = Test-IsWifiAdapter $a

    $isVpn = (-not $a.HardwareInterface) -and ($a.InterfaceDescription -notmatch 'Hyper-V|VMware|VirtualBox')
    if ($isVpn) {
        Write-Bad ('Трафик идёт через VPN/виртуальный адаптер: «{0}» ({1})' -f $a.Name, $a.InterfaceDescription)
        Write-Info 'VPN добавляет путь до своего сервера — пинг почти всегда выше. Выключайте VPN на время матча.'
        $phys = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if ($phys) { $script:IsWifi = Test-IsWifiAdapter $phys }
    } else {
        Write-Info ('Адаптер: {0} ({1}), скорость линка {2}' -f $a.Name, $a.InterfaceDescription, $a.LinkSpeed)
    }

    $otherVpn = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and -not $_.HardwareInterface -and $_.ifIndex -ne $a.ifIndex -and
        $_.InterfaceDescription -match 'TAP|Wintun|WireGuard|OpenVPN|VPN|Tunnel|Hamachi|ZeroTier|Radmin|Tailscale|Amnezia|sing-box|Hiddify'
    })
    foreach ($v in $otherVpn) { Write-Warn ('Активен VPN-адаптер «{0}» ({1}) — если не нужен, отключите' -f $v.Name, $v.InterfaceDescription) }

    if ($script:IsWifi) {
        Write-Warn 'Подключение по Wi-Fi. Кабель (Ethernet) — самый действенный способ убрать скачки пинга.'
        $wlan = (& netsh.exe wlan show interfaces 2>$null) | Out-String
        $signal = [regex]::Match($wlan, '(\d{1,3})\s*%')
        $band = [regex]::Match($wlan, '(?im)^\s*(Band|Диапазон)\s*:\s*(.+?)\s*$')
        $channel = [regex]::Match($wlan, '(?im)^\s*(Channel|Канал)\s*:\s*(\d+)')
        if ($signal.Success) {
            $s = [int]$signal.Groups[1].Value
            if ($s -lt 70) { Write-Warn ('Сигнал Wi-Fi {0}% — слабый. Поставьте роутер ближе/без стен или используйте кабель.' -f $s) }
            else { Write-Info ('Сигнал Wi-Fi: {0}%' -f $s) }
        }
        $bandText = $null
        if ($band.Success) { $bandText = $band.Groups[2].Value }
        elseif ($channel.Success) { if ([int]$channel.Groups[2].Value -le 14) { $bandText = '2.4 GHz' } else { $bandText = '5 GHz' } }
        if ($bandText) {
            if ($bandText -match '2[.,]4') { Write-Warn ('Диапазон {0}: он перегружен соседями. Подключитесь к сети 5 ГГц (или 6 ГГц).' -f $bandText) }
            else { Write-Ok ('Диапазон Wi-Fi: ' + $bandText) }
        }
    } elseif (-not $isVpn) {
        Write-Ok 'Подключение по кабелю — отлично'
        if ($a.LinkSpeed -match '^(10|100) Mbps') {
            Write-Warn ('Линк всего {0}: проверьте кабель (нужна категория 5e/6) и порт роутера.' -f $a.LinkSpeed)
        }
    }
}

# ------------------------------------------------------------------ Пинг

function Measure-Latency {
    param([System.Collections.Specialized.OrderedDictionary]$Targets, [int]$Seconds, [string]$Activity, [int]$IntervalMs = 250)
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $rtt = @{}; $sent = @{}
    foreach ($k in $Targets.Keys) { $rtt[$k] = New-Object System.Collections.Generic.List[int]; $sent[$k] = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        $roundStart = $sw.ElapsedMilliseconds
        foreach ($k in $Targets.Keys) {
            $sent[$k]++
            try {
                $reply = $pinger.Send($Targets[$k], 1000)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $rtt[$k].Add([int]$reply.RoundtripTime) }
            } catch { }
        }
        $pct = [math]::Min(100, [int]($sw.Elapsed.TotalSeconds * 100 / $Seconds))
        Write-Progress -Activity $Activity -Status ('{0} из {1} с' -f [int]$sw.Elapsed.TotalSeconds, $Seconds) -PercentComplete $pct
        $pause = $IntervalMs - ($sw.ElapsedMilliseconds - $roundStart)
        if ($pause -gt 0) { Start-Sleep -Milliseconds $pause }
    }
    Write-Progress -Activity $Activity -Completed

    foreach ($k in $Targets.Keys) {
        $v = $rtt[$k]
        $n = $v.Count
        $row = [ordered]@{ Target = $k; Received = $n; Loss = 100.0; Min = $null; Avg = $null; P95 = $null; Max = $null; Jitter = $null }
        if ($sent[$k] -gt 0) { $row.Loss = [math]::Round(100.0 * ($sent[$k] - $n) / $sent[$k], 1) }
        if ($n -gt 0) {
            $sorted = @($v | Sort-Object)
            $row.Min = $sorted[0]
            $row.Max = $sorted[$n - 1]
            $row.Avg = [math]::Round(($v | Measure-Object -Average).Average, 1)
            $row.P95 = $sorted[[math]::Max(0, [math]::Ceiling(0.95 * $n) - 1)]
            $diff = 0
            for ($i = 1; $i -lt $n; $i++) { $diff += [math]::Abs($v[$i] - $v[$i - 1]) }
            if ($n -gt 1) { $row.Jitter = [math]::Round($diff / ($n - 1), 1) } else { $row.Jitter = 0 }
        }
        [pscustomobject]$row
    }
}

function Show-Latency($Rows) {
    $Rows | Select-Object @{ n = 'Куда'; e = { $_.Target } },
                          @{ n = 'Мин, мс'; e = { $_.Min } },
                          @{ n = 'Сред, мс'; e = { $_.Avg } },
                          @{ n = '95%, мс'; e = { $_.P95 } },
                          @{ n = 'Макс, мс'; e = { $_.Max } },
                          @{ n = 'Джиттер, мс'; e = { $_.Jitter } },
                          @{ n = 'Потери, %'; e = { $_.Loss } } |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

$targets = [ordered]@{}
if ($script:Gateway) { $targets[('Роутер ' + $script:Gateway)] = $script:Gateway }
$targets['Cloudflare 1.1.1.1'] = '1.1.1.1'
$targets['Google 8.8.8.8'] = '8.8.8.8'
$routerKey = $null
if ($script:Gateway) { $routerKey = 'Роутер ' + $script:Gateway }

$idle = $null
Invoke-Step ('Пинг в покое ({0} с) — ничего не качайте, не смотрите видео' -f $Seconds) {
    $script:idle = @(Measure-Latency -Targets $targets -Seconds $Seconds -Activity 'Замер пинга')
    Show-Latency $script:idle

    $r = $script:idle | Where-Object { $_.Target -eq $routerKey } | Select-Object -First 1
    if ($r) {
        if ($r.Received -eq 0) {
            Write-Info 'Роутер не отвечает на ping (некоторые так настроены) — домашнюю сеть оценить нельзя.'
        } elseif ($r.Loss -gt 0 -or $r.Avg -gt 5 -or $r.Jitter -gt 3 -or $r.Max -gt 30) {
            Write-Bad 'Проблема уже между ПК и роутером (потери/скачки). Это вина домашней сети, а не провайдера.'
            if ($script:IsWifi) { Write-Info 'Решение: кабель; или 5 ГГц, ближе к роутеру, другой канал Wi-Fi.' }
            else { Write-Info 'Решение: другой кабель/порт роутера, перезагрузка роутера, свежий драйвер сетевой карты.' }
        } else {
            Write-Ok 'ПК ↔ роутер: стабильно'
        }
    }

    $net = @($script:idle | Where-Object { $_.Target -ne $routerKey -and $_.Received -gt 0 })
    if ($net.Count -eq 0) {
        Write-Bad 'Интернет-узлы не отвечают: нет интернета или ICMP блокируется.'
        return
    }
    $best = $net | Sort-Object Avg | Select-Object -First 1
    if (($net | Measure-Object -Property Loss -Maximum).Maximum -gt 1) {
        Write-Bad 'Есть потери пакетов до интернета — отсюда «телепорты» и задержка управления в матче.'
        Write-Info 'Если до роутера потерь нет — проблема в роутере или у провайдера: сохраните этот отчёт и покажите провайдеру.'
    }
    if ($best.Jitter -gt 8) { Write-Warn ('Высокий джиттер ({0} мс): пинг «гуляет», управление будет неровным.' -f $best.Jitter) }
    if ($best.Avg -le 25) { Write-Ok ('Базовый пинг до ближайших узлов: {0} мс — хорошо' -f $best.Avg) }
    elseif ($best.Avg -le 50) { Write-Info ('Базовый пинг до ближайших узлов: {0} мс — нормально' -f $best.Avg) }
    else { Write-Warn ('Базовый пинг до ближайших узлов: {0} мс — высокий (VPN? спутник/мобильный интернет? провайдер?)' -f $best.Avg) }
    Write-Info 'Пинг до серверов EA будет больше — он зависит от того, где стоит сервер матча.'
}

# ------------------------------------------------------------------ Bufferbloat

if (-not $NoLoadTest -and $script:idle) {
    Write-Section 'Тест под нагрузкой (bufferbloat) — главный источник лагов, когда кто-то дома качает'
    Write-Host '  1) Откройте в браузере тест скорости: speedtest.net, fast.com или speedtest.yandex.ru' -ForegroundColor White
    Write-Host '  2) Нажмите здесь Enter и СРАЗУ запустите тест скорости в браузере.' -ForegroundColor White
    Write-Host '     Пинг будет замеряться 35 секунд, пока идёт загрузка и отдача.' -ForegroundColor White
    $answer = Read-Host '  Enter — начать, S и Enter — пропустить'
    if ($answer -notmatch '^\s*[sSыЫ]') {
        Invoke-Step 'Пинг под нагрузкой' {
            $loadTargets = [ordered]@{}
            foreach ($k in $targets.Keys) { if ($k -ne 'Google 8.8.8.8') { $loadTargets[$k] = $targets[$k] } }
            $loaded = @(Measure-Latency -Targets $loadTargets -Seconds 35 -Activity 'Пинг под нагрузкой')
            Show-Latency $loaded

            $i = $script:idle | Where-Object { $_.Target -eq 'Cloudflare 1.1.1.1' } | Select-Object -First 1
            $l = $loaded | Where-Object { $_.Target -eq 'Cloudflare 1.1.1.1' } | Select-Object -First 1
            if (-not $i -or -not $l -or $i.Received -eq 0 -or $l.Received -eq 0) {
                Write-Warn 'Недостаточно ответов для оценки.'
                return
            }
            $delta = [math]::Round($l.P95 - $i.Avg, 1)
            $grade = 'F'
            if ($delta -lt 5) { $grade = 'A+' } elseif ($delta -lt 30) { $grade = 'A' } elseif ($delta -lt 60) { $grade = 'B' }
            elseif ($delta -lt 200) { $grade = 'C' } elseif ($delta -lt 400) { $grade = 'D' }
            $msg = 'Под нагрузкой пинг вырастает на {0} мс — оценка {1}' -f $delta, $grade
            if ($grade -eq 'A+' -or $grade -eq 'A') {
                Write-Ok $msg
            } else {
                Write-Bad $msg
                Write-Info 'Когда канал занят (закачки, видео, обновления на других устройствах), в игре будут лаги.'
                Write-Info 'Лечится на роутере: включите SQM / Smart Queue / Adaptive QoS (IntelliQoS на Keenetic)'
                Write-Info 'и ограничьте скорость на 85–90% от тарифа. Подробно — README, раздел «Роутер».'
            }
            $rl = $loaded | Where-Object { $_.Target -eq $routerKey } | Select-Object -First 1
            $ri = $script:idle | Where-Object { $_.Target -eq $routerKey } | Select-Object -First 1
            if ($rl -and $ri -and $rl.Received -gt 0 -and $ri.Received -gt 0 -and ($rl.P95 - $ri.Avg) -gt 20) {
                Write-Warn 'Даже пинг до роутера растёт под нагрузкой — узкое место в Wi-Fi или в самом роутере.'
            }
        }
    }
}

Write-Section 'Готово'
if ($transcribing) {
    Stop-Transcript | Out-Null
    Write-Info ('Отчёт сохранён: ' + $reportPath)
}
Write-Info 'Сравните результаты до и после 2_Optimize.bat и ручных шагов из README.'
Wait-Exit -NoPause:$NoPause
