#Requires -Version 5.1
<#
.SYNOPSIS
    Записывает пинг, потери, загрузку CPU/GPU и температуру видеокарты, пока вы играете матч.

.DESCRIPTION
    Запустите перед матчем, сыграйте 1–2 матча, вернитесь в окно (Alt+Tab) и нажмите Enter.
    Итог показывает, в какие минуты были скачки пинга и откуда они: домашняя сеть, провайдер или ПК.
    Сырые данные сохраняются в CSV на рабочий стол, итог — в текстовый файл и в буфер обмена.
#>
[CmdletBinding()]
param(
    [string]$ExeName = 'FC27.exe',
    [ValidateRange(200, 5000)] [int]$IntervalMs = 500,
    [switch]$NoPause
)

. (Join-Path $PSScriptRoot 'FC27-Common.ps1')

$desktop = [Environment]::GetFolderPath('Desktop')
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$csvPath = Join-Path $desktop ("FC27-match-$stamp.csv")
$reportPath = Join-Path $desktop ("FC27-match-$stamp.txt")
$gpuLog = Join-Path $env:TEMP ("FC27-gpu-$stamp.csv")
$gameProc = [IO.Path]::GetFileNameWithoutExtension($ExeName)

Write-Banner 'FC 27 Optimizer — запись пинга и нагрузки во время матча'
Write-Host '  1) Не закрывайте это окно.' -ForegroundColor White
Write-Host '  2) Запустите игру и сыграйте 1–2 онлайн-матча (Rivals, Champions, Сезоны и т. п.).' -ForegroundColor White
Write-Host '  3) Запомните примерное время, когда были лаги или «вата» в управлении.' -ForegroundColor White
Write-Host '  4) Вернитесь сюда (Alt+Tab) и нажмите Enter — появится итог.' -ForegroundColor White
Write-Host ''

$inet = Get-InternetRoute
$targets = [ordered]@{}
if ($inet -and $inet.Gateway) { $targets['Router'] = $inet.Gateway }
$targets['Internet'] = '1.1.1.1'
if ($inet -and $inet.Adapter) {
    $kind = 'кабель'
    if (Test-IsWifiAdapter $inet.Adapter) { $kind = 'Wi-Fi' }
    Write-Info ('Подключение: {0} ({1}), {2}' -f $inet.Adapter.Name, $inet.Adapter.InterfaceDescription, $kind)
}

$smi = Get-NvidiaSmiPath
$smiProc = $null
if ($smi) {
    $smiArgs = @('--query-gpu=timestamp,utilization.gpu,temperature.gpu,clocks.gr,power.draw,memory.used,pstate',
                 '--format=csv,noheader,nounits', '-l', '1', '-f', ('"{0}"' -f $gpuLog))
    try { $smiProc = Start-Process -FilePath $smi -ArgumentList $smiArgs -WindowStyle Hidden -PassThru -ErrorAction Stop } catch { }
}

Read-Host '  Нажмите Enter, чтобы начать запись' | Out-Null
Write-Info 'Запись идёт. Нажмите Enter в этом окне, когда закончите играть.'

$pinger = New-Object System.Net.NetworkInformation.Ping
$cores = [Environment]::ProcessorCount
$samples = New-Object System.Collections.Generic.List[object]
$sw = [Diagnostics.Stopwatch]::StartNew()
$tick = 0
$lastCpuAt = 0
$prevGameCpu = $null
$totalCpu = $null
$gameCpu = $null
$lost = @{}
foreach ($k in $targets.Keys) { $lost[$k] = 0 }

while ($true) {
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter -or $key.Key -eq [ConsoleKey]::Q) { break }
    }
    $roundStart = $sw.ElapsedMilliseconds
    $row = [ordered]@{ Time = (Get-Date).ToString('HH:mm:ss.f') }
    foreach ($k in $targets.Keys) {
        $ms = -1
        try {
            $reply = $pinger.Send($targets[$k], 1000)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $ms = [int]$reply.RoundtripTime }
        } catch { }
        if ($ms -lt 0) { $lost[$k]++ }
        $row[$k] = $ms
    }

    # Загрузка CPU — раз в 2 секунды, чтобы не мешать игре.
    if ($sw.ElapsedMilliseconds - $lastCpuAt -ge 2000) {
        $elapsed = $sw.ElapsedMilliseconds - $lastCpuAt
        $lastCpuAt = $sw.ElapsedMilliseconds
        try {
            $totalCpu = [int](Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
        } catch { $totalCpu = $null }
        $gameCpu = $null
        $gp = Get-Process -Name $gameProc -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gp) {
            try {
                $t = $gp.TotalProcessorTime.TotalMilliseconds
                if ($null -ne $prevGameCpu) { $gameCpu = [math]::Round(($t - $prevGameCpu) * 100 / ($elapsed * $cores), 1) }
                $prevGameCpu = $t
            } catch { $prevGameCpu = $null }
        } else {
            $prevGameCpu = $null
        }
    }
    $row['TotalCpu'] = $totalCpu
    $row['GameCpu'] = $gameCpu
    $row['GameRunning'] = [bool](Get-Process -Name $gameProc -ErrorAction SilentlyContinue)
    $samples.Add([pscustomobject]$row)

    $tick++
    if ($tick % 2 -eq 0) {
        $parts = @()
        foreach ($k in $targets.Keys) {
            $v = $row[$k]
            if ($v -lt 0) { $v = 'потеря' } else { $v = "$v мс" }
            $parts += ('{0}: {1} (потерь {2})' -f $k, $v, $lost[$k])
        }
        $line = ('  {0:mm\:ss}  {1}  CPU {2}%   ' -f $sw.Elapsed, ($parts -join '  '), $totalCpu)
        [Console]::Write("`r" + $line.PadRight(100).Substring(0, 100))
    }
    $pause = $IntervalMs - ($sw.ElapsedMilliseconds - $roundStart)
    if ($pause -gt 0) { Start-Sleep -Milliseconds $pause }
}
[Console]::WriteLine()

if ($smiProc) { try { Stop-Process -Id $smiProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
$samples | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'

# ------------------------------------------------------------------ Итог

$transcribing = $false
try { Start-Transcript -Path $reportPath -ErrorAction Stop | Out-Null; $transcribing = $true } catch { }

Write-Banner 'Итог записи во время матча'
$gameSamples = @($samples | Where-Object { $_.GameRunning })
Write-Info ('Длительность: {0:hh\:mm\:ss}, замеров: {1}, из них при запущенной игре: {2}' -f $sw.Elapsed, $samples.Count, $gameSamples.Count)
if ($gameSamples.Count -eq 0) {
    Write-Warn ('Процесс {0} не был запущен во время записи — ниже данные без игры.' -f $ExeName)
    $gameSamples = @($samples)
}

$spikeMinutes = @{}
foreach ($k in $targets.Keys) {
    $vals = @($gameSamples | ForEach-Object { $_.$k })
    $ok = @($vals | Where-Object { $_ -ge 0 } | Sort-Object)
    $lossPct = 0
    if ($vals.Count -gt 0) { $lossPct = [math]::Round(100.0 * ($vals.Count - $ok.Count) / $vals.Count, 2) }
    Write-Section ('Пинг: ' + $(if ($k -eq 'Router') { 'до роутера ' + $targets[$k] } else { 'до интернета 1.1.1.1' }))
    if ($ok.Count -eq 0) { Write-Warn 'Нет ответов'; continue }
    $median = $ok[[int][math]::Floor($ok.Count / 2)]
    $p95 = $ok[[math]::Max(0, [int][math]::Ceiling(0.95 * $ok.Count) - 1)]
    $p99 = $ok[[math]::Max(0, [int][math]::Ceiling(0.99 * $ok.Count) - 1)]
    $avg = [math]::Round(($ok | Measure-Object -Average).Average, 1)
    Write-Info ('медиана {0} мс, среднее {1}, 95% {2}, 99% {3}, максимум {4}, потери {5}%' -f $median, $avg, $p95, $p99, $ok[-1], $lossPct)

    $threshold = $median + 30
    $spikes = @($gameSamples | Where-Object { $_.$k -lt 0 -or $_.$k -gt $threshold })
    Write-Info ('Скачков (> {0} мс или потеря): {1}' -f $threshold, $spikes.Count)
    foreach ($s in $spikes) {
        $minute = $s.Time.Substring(0, 5)
        $keyName = $k + '|' + $minute
        $spikeMinutes[$keyName] = 1 + [int]$spikeMinutes[$keyName]
    }
    $worst = @($spikeMinutes.GetEnumerator() | Where-Object { $_.Key -like ($k + '|*') } |
        Sort-Object Value -Descending | Select-Object -First 8)
    if ($worst.Count -gt 0) {
        Write-Info ('Худшие минуты: ' + (($worst | ForEach-Object { '{0} ({1})' -f $_.Key.Split('|')[1], $_.Value }) -join ', '))
    }
}

Write-Section 'Процессор'
$tc = @($gameSamples | Where-Object { $null -ne $_.TotalCpu } | ForEach-Object { [int]$_.TotalCpu })
if ($tc.Count -gt 0) {
    $busy = @($tc | Where-Object { $_ -ge 90 }).Count
    Write-Info ('Загрузка всего CPU: средняя {0}%, максимум {1}%, ≥90% в {2}% времени' -f `
        [math]::Round(($tc | Measure-Object -Average).Average), ($tc | Measure-Object -Maximum).Maximum,
        [math]::Round(100.0 * $busy / $tc.Count))
}
$gc = @($gameSamples | Where-Object { $null -ne $_.GameCpu } | ForEach-Object { [double]$_.GameCpu })
if ($gc.Count -gt 0) {
    Write-Info ('Игра использует CPU: в среднем {0}%, максимум {1}% от всего процессора' -f `
        [math]::Round(($gc | Measure-Object -Average).Average, 1), ($gc | Measure-Object -Maximum).Maximum)
}

Write-Section 'Видеокарта'
if (Test-Path -LiteralPath $gpuLog) {
    $gpu = @(Get-Content -LiteralPath $gpuLog -ErrorAction SilentlyContinue | ForEach-Object {
        $f = $_ -split ',\s*'
        if ($f.Count -ge 7 -and $f[1] -match '^\d') {
            [pscustomobject]@{ Util = [double]$f[1]; Temp = [double]$f[2]; Clock = [double]$f[3]
                               Power = [double]($f[4] -replace '[^\d.]', ''); Mem = [double]$f[5]; PState = $f[6] }
        }
    })
    if ($gpu.Count -gt 0) {
        $load = @($gpu | Where-Object { $_.Util -ge 50 })
        Write-Info ('Загрузка GPU: средняя {0}%, ≥95% в {1}% времени' -f `
            [math]::Round(($gpu | Measure-Object Util -Average).Average), [math]::Round(100.0 * @($gpu | Where-Object { $_.Util -ge 95 }).Count / $gpu.Count))
        Write-Info ('Температура: средняя {0}°C, максимум {1}°C' -f `
            [math]::Round(($gpu | Measure-Object Temp -Average).Average), ($gpu | Measure-Object Temp -Maximum).Maximum)
        if ($load.Count -gt 0) {
            Write-Info ('Частота под нагрузкой: мин {0} / сред {1} МГц; мощность сред {2} Вт; видеопамять макс {3} МБ' -f `
                ($load | Measure-Object Clock -Minimum).Minimum, [math]::Round(($load | Measure-Object Clock -Average).Average),
                [math]::Round(($load | Measure-Object Power -Average).Average), ($load | Measure-Object Mem -Maximum).Maximum)
        }
    } else {
        Write-Info 'Данных от nvidia-smi нет'
    }
    Remove-Item -LiteralPath $gpuLog -ErrorAction SilentlyContinue
} else {
    Write-Info 'nvidia-smi недоступен (не NVIDIA?) — данные GPU не записаны'
}

Write-Section 'Файлы'
Write-Info ('Сырые данные: ' + (Split-Path $csvPath -Leaf))

if ($transcribing) {
    Stop-Transcript | Out-Null
    $text = Protect-ReportFile $reportPath
    try { Set-Clipboard -Value $text -ErrorAction Stop; Write-Ok 'Итог скопирован — вставьте его в чат (Ctrl+V).' } catch { }
    Write-Info ('Итог сохранён: ' + (Split-Path $reportPath -Leaf))
}
Wait-Exit -NoPause:$NoPause
