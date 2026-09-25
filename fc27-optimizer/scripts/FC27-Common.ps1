# FC27-Common.ps1 — общие функции для скриптов FC 27 Optimizer.
# Подключается из остальных скриптов через dot-source и сам ничего не меняет.

$script:BackupDir    = Join-Path $env:ProgramData 'FC27-Optimizer'
$script:BackupFile   = Join-Path $script:BackupDir 'backup.json'
# Свой план питания создаётся с фиксированным GUID: повторный запуск не плодит копии,
# а откат точно знает, какой план удалять.
$script:PlanGuid     = 'f0c27f0c-2700-4f27-a000-00000000fc27'
$script:PlanUltimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:PlanHigh     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:PlanBalanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:NetClassKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$script:TcpipIfKey   = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
$script:Stats        = @{ Changed = 0; Unchanged = 0; Errors = 0 }

# ---------------------------------------------------------------- вывод

function Write-Banner([string]$Title) {
    $line = '=' * 66
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ('  ' + $Title) -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan
}

function Write-Section([string]$Text) {
    Write-Host ''
    Write-Host ('--- ' + $Text + ' ---') -ForegroundColor Cyan
}

function Write-Ok([string]$Text)   { Write-Host ('  [OK] ' + $Text) -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host ('  [i]  ' + $Text) -ForegroundColor Gray }
function Write-Warn([string]$Text) { Write-Host ('  [!]  ' + $Text) -ForegroundColor Yellow }
function Write-Bad([string]$Text)  { Write-Host ('  [X]  ' + $Text) -ForegroundColor Red }
function Write-Plan([string]$Text) { Write-Host ('  [план] ' + $Text) -ForegroundColor Magenta }

function Invoke-Step {
    param([string]$Title, [scriptblock]$Action)
    Write-Section $Title
    try {
        & $Action
    } catch {
        $script:Stats.Errors++
        Write-Bad ('Ошибка: ' + $_.Exception.Message)
    }
}

function Wait-Exit([switch]$NoPause) {
    if ($NoPause) { return }
    Write-Host ''
    [void](Read-Host 'Нажмите Enter, чтобы закрыть окно')
}

# ---------------------------------------------------------------- права

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Перезапускает скрипт с правами администратора (через окно UAC) с теми же параметрами.
function Invoke-SelfElevate {
    param([string]$ScriptPath, [System.Collections.IDictionary]$BoundParameters)
    if (Test-IsAdmin) { return }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath))
    foreach ($kv in $BoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value.IsPresent) { $argList += ('-' + $kv.Key) }
        } else {
            # Завершающий «\» перед кавычкой сломал бы разбор командной строки.
            $argList += ('-' + $kv.Key)
            $argList += ('"{0}"' -f ([string]$kv.Value).TrimEnd('\'))
        }
    }
    Write-Host 'Нужны права администратора — подтвердите запрос Windows (UAC)...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
    } catch {
        Write-Bad 'Права администратора не получены. Запустите .bat-файл ещё раз и нажмите «Да».'
        Wait-Exit
    }
    exit
}

# ---------------------------------------------------------------- резервная копия

function Initialize-Backup {
    $script:BackupEntries = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $script:BackupFile) {
        $data = Get-Content -LiteralPath $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($e in @($data.Entries)) {
            if ($null -ne $e) { [void]$script:BackupEntries.Add($e) }
        }
    }
}

function Save-Backup {
    if (-not (Test-Path -LiteralPath $script:BackupDir)) {
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }
    $obj = [ordered]@{
        Tool    = 'FC27-Optimizer'
        Updated = (Get-Date).ToString('s')
        Entries = @($script:BackupEntries)
    }
    ConvertTo-Json -InputObject $obj -Depth 6 | Set-Content -LiteralPath $script:BackupFile -Encoding UTF8
}

# Запоминает исходное состояние. Если запись с таким Id уже есть (повторный запуск),
# остаётся самая первая — откат вернёт настройки «как было до оптимизатора».
function Add-BackupEntry([hashtable]$Entry) {
    if ($script:DryRun) { return }
    foreach ($e in $script:BackupEntries) {
        if ($e.Id -eq $Entry.Id) { return }
    }
    [void]$script:BackupEntries.Add([pscustomobject]$Entry)
    Save-Backup
}

# ---------------------------------------------------------------- реестр

function Get-RegValueInfo([string]$Path, [string]$Name) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return $null }
    if (-not ($key.GetValueNames() -contains $Name)) { return $null }
    return [pscustomobject]@{
        Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Kind  = $key.GetValueKind($Name).ToString()
    }
}

# Ключи, которых ещё нет, от самого верхнего к самому глубокому.
function Get-MissingRegKeys([string]$Path) {
    $missing = @()
    $p = $Path
    while ($p -and -not (Test-Path -LiteralPath $p)) {
        $missing = @($p) + $missing
        $p = Split-Path -Path $p -Parent
    }
    return $missing
}

function Set-RegValue {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] $Value,
        [ValidateSet('DWord', 'String')] [string]$Type = 'DWord',
        [string]$Label
    )
    if (-not $Label) { $Label = $Name }
    $current = Get-RegValueInfo -Path $Path -Name $Name
    if ($current -and $current.Kind -eq $Type -and ([string]$current.Value) -eq ([string]$Value)) {
        $script:Stats.Unchanged++
        Write-Info ($Label + ' — уже настроено')
        return
    }
    if ($script:DryRun) {
        Write-Plan $Label
        return
    }
    foreach ($k in (Get-MissingRegKeys $Path)) {
        Add-BackupEntry @{ Id = "KEY|$k"; Type = 'RegKey'; Path = $k }
    }
    if ($current) {
        Add-BackupEntry @{ Id = "REG|$Path|$Name"; Type = 'Registry'; Path = $Path; Name = $Name;
                           Existed = $true; Value = $current.Value; Kind = $current.Kind }
    } else {
        Add-BackupEntry @{ Id = "REG|$Path|$Name"; Type = 'Registry'; Path = $Path; Name = $Name; Existed = $false }
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    $script:Stats.Changed++
    Write-Ok $Label
}

# ---------------------------------------------------------------- план питания

function Invoke-PowerCfg([string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powercfg.exe @Arguments 2>&1 | ForEach-Object { [string]$_ }
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out -join "`n") }
    } finally {
        $ErrorActionPreference = $old
    }
}

function Get-ActivePowerPlan {
    $r = Invoke-PowerCfg @('/getactivescheme')
    $m = [regex]::Match($r.Output, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*\(([^)]*)\)')
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{ Guid = $m.Groups[1].Value.ToLower(); Name = $m.Groups[2].Value.Trim() }
}

function Test-PowerPlanExists([string]$Guid) {
    return ((Invoke-PowerCfg @('/list')).Output -match [regex]::Escape($Guid))
}

# ---------------------------------------------------------------- сеть

# Ключ драйвера адаптера в реестре (там живёт флажок «Разрешить отключение для экономии энергии»).
function Get-AdapterClassKey([string]$InterfaceGuid) {
    foreach ($sub in @(Get-ChildItem -LiteralPath $script:NetClassKey -ErrorAction SilentlyContinue)) {
        if ($sub.PSChildName -notmatch '^\d{4}$') { continue }
        $id = (Get-ItemProperty -LiteralPath $sub.PSPath -Name 'NetCfgInstanceId' -ErrorAction SilentlyContinue).NetCfgInstanceId
        if ($id -and $id -eq $InterfaceGuid) { return (Join-Path $script:NetClassKey $sub.PSChildName) }
    }
    return $null
}

# Интерфейс и шлюз, через которые реально уходит трафик в интернет (учитывает VPN с маршрутами 0/1 + 128/1).
function Get-InternetRoute {
    $route = $null
    try {
        $route = Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop |
            Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } | Select-Object -First 1
    } catch { }
    if (-not $route) {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } | Select-Object -First 1
    }
    if (-not $route) { return $null }
    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    $gateway = $null
    if ($route.NextHop -and $route.NextHop -ne '0.0.0.0') { $gateway = $route.NextHop }
    if (-not $gateway) {
        # У VPN маршрут «на канале» — ищем шлюз физического адаптера отдельно.
        $gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } | Select-Object -First 1
        if ($gw) { $gateway = $gw.NextHop }
    }
    return [pscustomobject]@{ Adapter = $adapter; Gateway = $gateway }
}

function Test-IsWifiAdapter($Adapter) {
    # NdisPhysicalMedium 9 = Native 802.11
    return ($null -ne $Adapter -and [int]$Adapter.NdisPhysicalMedium -eq 9)
}

# ---------------------------------------------------------------- диагностика

# Выполняет блок в отдельном процессе с ограничением по времени:
# запросы к хранилищу (Get-PhysicalDisk) на некоторых ПК зависают намертво.
function Invoke-WithTimeout {
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [int]$Seconds = 20)
    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    try {
        if (Wait-Job -Job $job -Timeout $Seconds) { return (Receive-Job -Job $job -ErrorAction SilentlyContinue) }
        return $null
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

# Физические диски и буквы томов на них. $null — если запрос не уложился в таймаут.
function Get-DiskInventory {
    return Invoke-WithTimeout -Seconds 25 -ScriptBlock {
        $letters = @{}
        foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue)) {
            if ($p.DriveLetter -and [string]$p.DriveLetter -match '^[A-Z]$') {
                $letters[[string]$p.DiskNumber] = [string]$letters[[string]$p.DiskNumber] + [string]$p.DriveLetter
            }
        }
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $media = [string]$d.MediaType
            if ($media -eq '3') { $media = 'HDD' } elseif ($media -eq '4') { $media = 'SSD' }
            $bus = [string]$d.BusType
            if ($bus -eq '17') { $bus = 'NVMe' } elseif ($bus -eq '11') { $bus = 'SATA' } elseif ($bus -eq '7') { $bus = 'USB' }
            if ($media -notmatch 'SSD|HDD') {
                if ($bus -eq 'NVMe') { $media = 'SSD' }
                elseif ($d.SpindleSpeed -eq 0) { $media = 'SSD' }
                elseif ($d.SpindleSpeed -gt 0 -and $d.SpindleSpeed -lt 4294967295) { $media = 'HDD' }
            }
            [pscustomobject]@{
                Disk    = [string]$d.DeviceId
                Letters = [string]$letters[[string]$d.DeviceId]
                Model   = [string]$d.FriendlyName
                Type    = $media
                Bus     = $bus
                SizeGB  = [math]::Round($d.Size / 1GB)
                Health  = [string]$d.HealthStatus
            }
        }
    }
}

function Get-NvidiaSmiPath {
    $cmd = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($p in @((Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
                     (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# Часть утилит (netsh в Windows 11 24H2) пишет UTF-8, а консоль читает их как CP866 — получается «╨Ч╨░╨┐...».
function Repair-ConsoleText([string]$Text) {
    if ($Text -notmatch '[╨╤]') { return $Text }
    try { return [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(866).GetBytes($Text)) } catch { return $Text }
}

function Test-PrivateIPv4([string]$Address) {
    return ($Address -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|127\.|169\.254\.)')
}

# Убирает из готового отчёта имя пользователя, имя ПК и MAC-адреса.
function Protect-ReportFile([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    # Папка профиля может называться не так, как учётная запись (например, у аккаунта Microsoft).
    $profileLeaf = $null
    if ($env:USERPROFILE) { $profileLeaf = Split-Path -Path $env:USERPROFILE -Leaf }
    $names = @($env:USERNAME, $profileLeaf, $env:COMPUTERNAME, $env:USERDOMAIN) |
        Where-Object { $_ -and $_.Length -ge 2 } | Select-Object -Unique | Sort-Object Length -Descending
    foreach ($n in $names) {
        $text = [regex]::Replace($text, '(?<!\w)' + [regex]::Escape($n) + '(?!\w)', '<скрыто>',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $text = [regex]::Replace($text, '(?<![0-9A-Fa-f])([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])', '<MAC>')
    # MAC без разделителей (параметр адаптера «Network Address»); хвост GUID после «-» не трогаем.
    $text = [regex]::Replace($text, '(?<![0-9A-Fa-f-])(?=[0-9]*[A-Fa-f])[0-9A-Fa-f]{12}(?![0-9A-Fa-f-])', '<MAC>')
    $text = [regex]::Replace($text, 'S-1-5-21(-\d+)+', '<SID>')
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($true)))
    return $text
}

# ---------------------------------------------------------------- поиск игры

function Get-GameNamePattern([string]$ExeName) {
    $m = [regex]::Match($ExeName, '\d+')
    if ($m.Success) { return ('FC\W{0,3}' + $m.Value + '(?!\d)') }
    return [regex]::Escape([IO.Path]::GetFileNameWithoutExtension($ExeName))
}

function Get-SteamLibraryRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $steamDirs = @()
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        $v = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($v -and $v.SteamPath)   { $steamDirs += ($v.SteamPath -replace '/', '\') }
        if ($v -and $v.InstallPath) { $steamDirs += $v.InstallPath }
    }
    foreach ($dir in ($steamDirs | Select-Object -Unique)) {
        $roots.Add($dir)
        $vdf = Join-Path $dir 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $text = [string](Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue)
            foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                $roots.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    return @($roots | Select-Object -Unique)
}

function Find-GameExe {
    param([string]$ExeName = 'FC27.exe')
    $pattern = Get-GameNamePattern $ExeName
    $candidates = New-Object System.Collections.Generic.List[string]

    # 1. «Установка и удаление программ» — туда пишут и EA app, и Steam.
    $uninstall = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($e in @(Get-ItemProperty -Path $uninstall -ErrorAction SilentlyContinue)) {
        if ($e.DisplayName -match $pattern -and $e.InstallLocation) { $candidates.Add([string]$e.InstallLocation) }
    }

    # 2. Типовые папки на всех локальных дисках и библиотеки Steam.
    $relative = @('Program Files\EA Games', 'Program Files (x86)\EA Games', 'EA Games', 'Games', 'Games\EA Games',
                  'Program Files\Epic Games', 'Epic Games', 'Program Files (x86)\Steam\steamapps\common',
                  'Steam\steamapps\common', 'SteamLibrary\steamapps\common')
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne [IO.DriveType]::Fixed -or -not $d.IsReady) { continue }
        foreach ($r in $relative) { $roots.Add((Join-Path $d.RootDirectory.FullName $r)) }
    }
    foreach ($lib in (Get-SteamLibraryRoots)) { $roots.Add((Join-Path $lib 'steamapps\common')) }
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.Name -match $pattern) { $candidates.Add($dir.FullName) }
        }
    }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $direct = Join-Path $c $ExeName
        if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
        $found = Get-ChildItem -LiteralPath $c -Filter $ExeName -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

# Путь из параметра -GamePath (файл или папка) либо автопоиск.
function Resolve-GameExe([string]$GamePath, [string]$ExeName) {
    if ($GamePath) {
        if (Test-Path -LiteralPath $GamePath -PathType Leaf) { return (Resolve-Path -LiteralPath $GamePath).Path }
        if (Test-Path -LiteralPath $GamePath -PathType Container) {
            $found = Get-ChildItem -LiteralPath $GamePath -Filter $ExeName -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) { return $found.FullName }
        }
        Write-Warn ("По пути «{0}» {1} не найден — пробую автопоиск" -f $GamePath, $ExeName)
    }
    return (Find-GameExe -ExeName $ExeName)
}
