#Requires -Version 5.1
<#
.SYNOPSIS
    Оптимизирует Windows 10/11 под EA SPORTS FC 27: меньше просадок FPS, задержек и скачков пинга.

.DESCRIPTION
    Меняет только стандартные настройки Windows (реестр, план питания, сетевой адаптер).
    Файлы игры и античит не затрагиваются.
    Исходные значения сохраняются в %ProgramData%\FC27-Optimizer\backup.json,
    откат — скриптом FC27-Restore.ps1 (3_Restore.bat).

.PARAMETER GamePath
    Путь к FC27.exe или к папке игры, если автопоиск её не нашёл.

.PARAMETER ExeName
    Имя exe-файла игры. По умолчанию FC27.exe (для FC 26 укажите FC26.exe).

.PARAMETER DryRun
    Только показать, что будет изменено. Ничего не меняет и не требует прав администратора.

.EXAMPLE
    .\FC27-Optimize.ps1 -DryRun

.EXAMPLE
    .\FC27-Optimize.ps1 -GamePath "D:\Games\EA SPORTS FC 27"
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$ExeName = 'FC27.exe',
    [switch]$SkipPowerPlan,
    [switch]$SkipNetwork,
    [switch]$SkipGamePriority,
    [switch]$SkipRestorePoint,
    [switch]$DryRun,
    [switch]$NoPause
)

. (Join-Path $PSScriptRoot 'FC27-Common.ps1')

if (-not $DryRun) { Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters }
$script:DryRun = [bool]$DryRun
Initialize-Backup

Write-Banner 'FC 27 Optimizer — оптимизация Windows под EA SPORTS FC 27'
if ($DryRun) {
    Write-Warn 'Режим просмотра (-DryRun): ничего не меняется, показывается только план.'
} else {
    Write-Info ('Резервная копия исходных настроек: ' + $script:BackupFile)
}

# ------------------------------------------------------------------ 0. Точка восстановления

if (-not $SkipRestorePoint -and -not $DryRun) {
    Write-Section 'Точка восстановления Windows'
    try {
        $warnings = $null
        Checkpoint-Computer -Description 'FC27 Optimizer' -RestorePointType 'MODIFY_SETTINGS' `
            -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable warnings
        if ($warnings) {
            Write-Info 'Windows создаёт не больше одной точки в сутки — используется недавняя.'
        } else {
            Write-Ok 'Точка восстановления создана'
        }
    } catch {
        Write-Warn ('Не создана: ' + $_.Exception.Message)
        Write-Info 'Обычно это значит, что выключена «Защита системы». Не страшно: откат есть в 3_Restore.bat.'
    }
}

# ------------------------------------------------------------------ Поиск игры

Write-Section 'Поиск игры'
$gameExe = Resolve-GameExe -GamePath $GamePath -ExeName $ExeName
if ($gameExe) {
    $ExeName = Split-Path -Path $gameExe -Leaf
    Write-Ok ('Найдена: ' + $gameExe)
} else {
    Write-Warn ($ExeName + ' не найден. Настройки по имени процесса применятся, но выбор видеокарты — нет.')
    Write-Info 'Укажите путь вручную: 2_Optimize.bat -GamePath "D:\Games\EA SPORTS FC 27"'
}

# ------------------------------------------------------------------ 1. План питания

if (-not $SkipPowerPlan) {
    Invoke-Step 'План питания «FC27 Max Performance»' {
        $active = Get-ActivePowerPlan
        if ($active -and $active.Guid -ne $script:PlanGuid) {
            Add-BackupEntry @{ Id = 'PLAN'; Type = 'PowerPlan'; PreviousGuid = $active.Guid; OurGuid = $script:PlanGuid }
        }
        if ($DryRun) {
            Write-Plan 'Создать план на основе «Максимальная производительность» и сделать его активным'
            Write-Plan 'В плане: без засыпания USB (геймпад), PCIe и Wi-Fi без энергосбережения, CPU без парковки ядер'
            return
        }

        if (-not (Test-PowerPlanExists $script:PlanGuid)) {
            foreach ($src in @($script:PlanUltimate, $script:PlanHigh, 'SCHEME_CURRENT')) {
                [void](Invoke-PowerCfg @('/duplicatescheme', $src, $script:PlanGuid))
                if (Test-PowerPlanExists $script:PlanGuid) { break }
            }
        }
        if (-not (Test-PowerPlanExists $script:PlanGuid)) { throw 'не удалось создать план питания' }
        [void](Invoke-PowerCfg @('/changename', $script:PlanGuid, 'FC27 Max Performance', 'Created by FC27 Optimizer'))

        # subgroup, setting, value, применять и на батарее
        $settings = @(
            @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0,   $true,  'USB не засыпает (геймпад не отваливается)'),
            @('501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', 0,   $true,  'PCI Express: без энергосбережения'),
            @('19cbb8fa-5279-450e-9fac-8a3d5fedd0c1', '12bbebe6-58d6-4636-95bb-3217ef867c1a', 0,   $true,  'Wi-Fi адаптер: максимальная производительность'),
            @('54533251-82be-4824-96c1-47b60b740d00', '893dee8e-2bef-41e0-89c6-b55d0929964c', 100, $false, 'Процессор: минимальная частота 100% (от сети)'),
            @('54533251-82be-4824-96c1-47b60b740d00', '0cc5b647-c1df-4637-891a-dec35c318583', 100, $false, 'Процессор: без парковки ядер (от сети)'),
            @('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e', 0,   $false, 'Диски не отключаются (от сети)')
        )
        foreach ($s in $settings) {
            $r = Invoke-PowerCfg @('/setacvalueindex', $script:PlanGuid, $s[0], $s[1], [string]$s[2])
            if ($s[3]) { [void](Invoke-PowerCfg @('/setdcvalueindex', $script:PlanGuid, $s[0], $s[1], [string]$s[2])) }
            if ($r.Code -eq 0) { Write-Ok $s[4] } else { Write-Info ($s[4] + ' — не поддерживается этим ПК, пропущено') }
        }

        [void](Invoke-PowerCfg @('/setactive', $script:PlanGuid))
        $now = Get-ActivePowerPlan
        if ($now -and $now.Guid -eq $script:PlanGuid) {
            $script:Stats.Changed++
            Write-Ok 'План «FC27 Max Performance» активен'
        } else {
            Write-Warn 'Windows не дала переключить план (так бывает на ноутбуках с Modern Standby).'
            Write-Info 'Включите вручную: Параметры → Система → Питание → Режим питания → «Максимальная производительность».'
        }
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if ($battery) { Write-Info 'Ноутбук: играйте от сети и включите «Турбо/Производительность» в фирменной утилите.' }
    }
}

# ------------------------------------------------------------------ 2. Игровой режим и Xbox Game Bar

Invoke-Step 'Игровой режим и Xbox Game Bar' {
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 -Label 'Игровой режим Windows: включён'
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1 -Label 'Игровой режим разрешён для всех игр'
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0 `
        -Label 'Кнопка Xbox на геймпаде больше не открывает Game Bar посреди матча'
    Set-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 -Label 'Фоновая запись игры (Game DVR): выключена'
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 `
        -Label 'Запись клипов Xbox Game Bar: выключена'
}

# ------------------------------------------------------------------ 3. Планировщик мультимедиа (MMCSS)

Invoke-Step 'Приоритет игр в планировщике Windows' {
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-RegValue $mm 'NetworkThrottlingIndex' -1 -Label 'Ограничение сети при воспроизведении медиа: выключено'
    Set-RegValue $mm 'SystemResponsiveness' 10 -Label 'Резерв CPU для фоновых задач: 10% (минимум, по умолчанию 20%)'
    $games = $mm + '\Tasks\Games'
    Set-RegValue $games 'GPU Priority' 8 -Label 'Игры: приоритет GPU 8'
    Set-RegValue $games 'Priority' 6 -Label 'Игры: приоритет CPU 6'
    Set-RegValue $games 'Scheduling Category' 'High' -Type String -Label 'Игры: категория планирования High'
    Set-RegValue $games 'SFIO Priority' 'High' -Type String -Label 'Игры: приоритет ввода-вывода High'
}

# ------------------------------------------------------------------ 4. Настройки для самой игры

Invoke-Step ("Настройки для {0}" -f $ExeName) {
    if (-not $SkipGamePriority) {
        $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $ExeName + '\PerfOptions'
        Set-RegValue $ifeo 'CpuPriorityClass' 3 -Label 'Процесс игры запускается с высоким приоритетом CPU'
    }
    if ($gameExe) {
        Set-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $gameExe 'GpuPreference=2;' -Type String `
            -Label 'Игра всегда запускается на мощной (дискретной) видеокарте'
    }

    # DSCP 46 (Expedited Forwarding): роутеры с QoS/WMM пропускают такие пакеты первыми,
    # в Wi-Fi они попадают в самую приоритетную очередь (Voice).
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS' 'Do not use NLA' '1' -Type String `
        -Label 'QoS-метки разрешены на домашнем (не доменном) ПК'
    $qosName = 'FC27 Optimizer - ' + [IO.Path]::GetFileNameWithoutExtension($ExeName)
    $existing = Get-NetQosPolicy -Name $qosName -ErrorAction SilentlyContinue
    if ($existing) {
        $script:Stats.Unchanged++
        Write-Info 'Приоритет сетевых пакетов игры (DSCP 46) — уже настроено'
    } elseif ($DryRun) {
        Write-Plan 'Пометить сетевые пакеты игры как приоритетные (DSCP 46)'
    } else {
        New-NetQosPolicy -Name $qosName -AppPathNameMatchCondition $ExeName -DSCPAction 46 -NetworkProfile All `
            -ErrorAction Stop | Out-Null
        Add-BackupEntry @{ Id = "QOS|$qosName"; Type = 'QosPolicy'; Name = $qosName }
        $script:Stats.Changed++
        Write-Ok 'Сетевые пакеты игры помечены как приоритетные (DSCP 46)'
    }
}

# ------------------------------------------------------------------ 5. Сеть

if (-not $SkipNetwork) {
    Invoke-Step 'Сеть: Windows Update не раздаёт обновления через ваш канал' {
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 `
            -Label 'Раздача обновлений другим ПК (Delivery Optimization): выключена'
    }

    Invoke-Step 'Сеть: сетевой адаптер без энергосбережения и лишних задержек' {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
        if ($adapters.Count -eq 0) {
            Write-Warn 'Нет подключённых физических сетевых адаптеров'
            return
        }
        # RegistryKeyword не зависит от языка Windows; отсутствующие у драйвера параметры пропускаются.
        $tweaks = @(
            @{ Kw = '*EEE';                 Val = '0'; Label = 'Energy Efficient Ethernet: выкл' },
            @{ Kw = 'EEELinkAdvertisement'; Val = '0'; Label = 'Energy Efficient Ethernet (Intel): выкл' },
            @{ Kw = 'AdvancedEEE';          Val = '0'; Label = 'Advanced EEE (Realtek): выкл' },
            @{ Kw = 'GreenEthernet';        Val = '0'; Label = 'Green Ethernet (Realtek): выкл' },
            @{ Kw = 'EnableGreenEthernet';  Val = '0'; Label = 'Green Ethernet: выкл' },
            @{ Kw = 'PowerSavingMode';      Val = '0'; Label = 'Power Saving Mode (Realtek): выкл' },
            @{ Kw = 'ULPMode';              Val = '0'; Label = 'Ultra Low Power (Intel): выкл' },
            @{ Kw = '*FlowControl';         Val = '0'; Label = 'Flow Control: выкл' },
            @{ Kw = '*InterruptModeration'; Val = '0'; Label = 'Interrupt Moderation (пакетирование прерываний): выкл' },
            @{ Kw = 'RoamAggressiveness';   Val = '0'; Label = 'Wi-Fi: минимальная агрессивность роуминга (меньше фоновых сканирований)'; WifiOnly = $true }
        )
        $toRestart = @()
        foreach ($a in $adapters) {
            $isWifi = Test-IsWifiAdapter $a
            $kind = 'кабель'
            if ($isWifi) { $kind = 'Wi-Fi' }
            Write-Host ("  Адаптер «{0}» — {1} ({2}, {3})" -f $a.Name, $a.InterfaceDescription, $kind, $a.LinkSpeed) -ForegroundColor White
            $changedBefore = $script:Stats.Changed
            # Имена адаптеров и ключевые слова вроде «*EEE» командлеты считают шаблонами,
            # поэтому работаем с объектами и точным сравнением.
            $props = @($a | Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue)

            foreach ($t in $tweaks) {
                if ($t.WifiOnly -and -not $isWifi) { continue }
                $p = $props | Where-Object { $_.RegistryKeyword -eq $t.Kw } | Select-Object -First 1
                if (-not $p) { continue }
                $cur = [string]($p.RegistryValue | Select-Object -First 1)
                if ($cur -eq $t.Val) {
                    $script:Stats.Unchanged++
                    Write-Info ($t.Label + ' — уже настроено')
                    continue
                }
                if ($p.ValidRegistryValues -and -not (@($p.ValidRegistryValues) -contains $t.Val)) { continue }
                if ($DryRun) { Write-Plan $t.Label; continue }
                try {
                    Add-BackupEntry @{ Id = ('NETADV|' + $a.InterfaceGuid + '|' + $t.Kw); Type = 'NetAdv';
                                       InterfaceGuid = $a.InterfaceGuid; AdapterName = $a.Name; Keyword = $t.Kw; Value = $cur }
                    $p | Set-NetAdapterAdvancedProperty -RegistryValue $t.Val -NoRestart -ErrorAction Stop
                    $script:Stats.Changed++
                    Write-Ok $t.Label
                } catch {
                    $script:Stats.Errors++
                    Write-Bad ($t.Label + ' — ошибка: ' + $_.Exception.Message)
                }
            }

            # Флажок «Разрешить отключение этого устройства для экономии энергии» (24 = снят).
            $classKey = Get-AdapterClassKey $a.InterfaceGuid
            if ($classKey) {
                Set-RegValue $classKey 'PnPCapabilities' 24 -Label 'Windows не отключает адаптер ради экономии энергии'
            }

            # Отключение алгоритма Нейгла и отложенных ACK для TCP.
            $ifKey = $script:TcpipIfKey + '\' + $a.InterfaceGuid
            if (Test-Path -LiteralPath $ifKey) {
                Set-RegValue $ifKey 'TcpAckFrequency' 1 -Label 'TCP: подтверждения без задержки (TcpAckFrequency)'
                Set-RegValue $ifKey 'TCPNoDelay' 1 -Label 'TCP: отправка без буферизации (Nagle off)'
            }

            if ($script:Stats.Changed -gt $changedBefore) { $toRestart += $a }
        }

        if ($toRestart.Count -gt 0 -and -not $DryRun) {
            Write-Warn 'Перезапускаю сетевой адаптер — интернет пропадёт на 5–15 секунд...'
            foreach ($r in $toRestart) {
                $r | Restart-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue
            }
            Write-Ok 'Адаптер перезапущен'
        }
    }
}

# ------------------------------------------------------------------ Итог

Write-Section 'Итог'
if ($DryRun) {
    Write-Info 'Это был просмотр. Чтобы применить, запустите 2_Optimize.bat без -DryRun.'
} else {
    Write-Host ("  Изменено: {0}   Уже было настроено: {1}   Ошибок: {2}" -f `
        $script:Stats.Changed, $script:Stats.Unchanged, $script:Stats.Errors) -ForegroundColor White
    Write-Host ''
    Write-Warn 'ПЕРЕЗАГРУЗИТЕ компьютер, чтобы все настройки вступили в силу.'
    Write-Info 'Дальше — ручные шаги из README.md: драйвер видеокарты, настройки игры, роутер (QoS/SQM).'
    Write-Info 'Проверить результат: 1_Check.bat.   Вернуть всё как было: 3_Restore.bat.'
}
Wait-Exit -NoPause:$NoPause
