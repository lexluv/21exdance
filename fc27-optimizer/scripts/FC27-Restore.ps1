#Requires -Version 5.1
<#
.SYNOPSIS
    Возвращает все настройки, изменённые FC27-Optimize.ps1, к исходным значениям.

.DESCRIPTION
    Читает %ProgramData%\FC27-Optimizer\backup.json и откатывает изменения в обратном порядке:
    реестр, параметры сетевого адаптера, QoS-политику и план питания.
#>
[CmdletBinding()]
param(
    [switch]$NoPause
)

. (Join-Path $PSScriptRoot 'FC27-Common.ps1')
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

Write-Banner 'FC 27 Optimizer — откат изменений'

if (-not (Test-Path -LiteralPath $script:BackupFile)) {
    Write-Warn ('Резервная копия не найдена: ' + $script:BackupFile)
    Write-Info 'Оптимизация не запускалась или уже была отменена — откатывать нечего.'
    Wait-Exit -NoPause:$NoPause
    exit
}

Initialize-Backup
$entries = @($script:BackupEntries)
[array]::Reverse($entries)
$failed = 0
$restartAdapters = @{}

foreach ($e in $entries) {
    try {
        switch ($e.Type) {
            'Registry' {
                if ($e.Existed) {
                    $kind = [Microsoft.Win32.RegistryValueKind]$e.Kind
                    $value = $e.Value
                    switch ($kind) {
                        'DWord'       { $value = [int]$value }
                        'QWord'       { $value = [long]$value }
                        'MultiString' { $value = [string[]]@($value) }
                        'Binary'      { $value = [byte[]]@($value) }
                        default       { $value = [string]$value }
                    }
                    if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                    New-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $value -PropertyType $kind -Force -ErrorAction Stop | Out-Null
                    Write-Ok ('{0} → {1}' -f $e.Name, $e.Value)
                } elseif (Get-RegValueInfo -Path $e.Path -Name $e.Name) {
                    Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction Stop
                    Write-Ok ('{0} — удалено (раньше не было)' -f $e.Name)
                }
            }
            'RegKey' {
                $key = Get-Item -LiteralPath $e.Path -ErrorAction SilentlyContinue
                if ($key -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
                    Remove-Item -LiteralPath $e.Path -ErrorAction Stop
                }
            }
            'NetAdv' {
                $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $e.InterfaceGuid } |
                    Select-Object -First 1
                if (-not $a) {
                    Write-Info ('Адаптер «{0}» не найден — пропущено {1}' -f $e.AdapterName, $e.Keyword)
                } else {
                    # Точное сравнение: «*EEE» и т. п. командлеты иначе считают шаблоном.
                    $p = $a | Get-NetAdapterAdvancedProperty -ErrorAction Stop |
                        Where-Object { $_.RegistryKeyword -eq $e.Keyword } | Select-Object -First 1
                    if ($p) {
                        $p | Set-NetAdapterAdvancedProperty -RegistryValue ([string]$e.Value) -NoRestart -ErrorAction Stop
                        $restartAdapters[[string]$a.InterfaceGuid] = $a
                        Write-Ok ('{0}: {1} → {2}' -f $a.Name, $e.Keyword, $e.Value)
                    }
                }
            }
            'QosPolicy' {
                if (Get-NetQosPolicy -Name $e.Name -ErrorAction SilentlyContinue) {
                    Remove-NetQosPolicy -Name $e.Name -Confirm:$false -ErrorAction Stop
                    Write-Ok ('QoS-политика «{0}» удалена' -f $e.Name)
                }
            }
            'PowerPlan' {
                $target = $e.PreviousGuid
                if (-not $target -or -not (Test-PowerPlanExists $target)) { $target = $script:PlanBalanced }
                [void](Invoke-PowerCfg @('/setactive', $target))
                if (Test-PowerPlanExists $e.OurGuid) { [void](Invoke-PowerCfg @('/delete', $e.OurGuid)) }
                Write-Ok 'Прежний план питания снова активен, план «FC27 Max Performance» удалён'
            }
        }
    } catch {
        $failed++
        Write-Bad ('{0} {1}: {2}' -f $e.Type, $e.Id, $_.Exception.Message)
    }
}

if ($restartAdapters.Count -gt 0) {
    Write-Warn 'Перезапускаю сетевой адаптер — интернет пропадёт на 5–15 секунд...'
    foreach ($a in $restartAdapters.Values) { $a | Restart-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue }
}

Write-Section 'Итог'
if ($failed -eq 0) {
    $done = Join-Path $script:BackupDir ('backup-restored-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $script:BackupFile -Destination $done -Force
    Write-Ok 'Все изменения отменены.'
    Write-Warn 'Перезагрузите компьютер.'
} else {
    Write-Warn ('Не удалось откатить пунктов: {0}. Резервная копия сохранена — можно запустить откат ещё раз.' -f $failed)
    Write-Info 'Крайний вариант: Панель управления → Восстановление → точка «FC27 Optimizer».'
}
Wait-Exit -NoPause:$NoPause
