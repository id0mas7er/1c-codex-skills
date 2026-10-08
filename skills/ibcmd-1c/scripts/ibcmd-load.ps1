<#
.SYNOPSIS
  Частичная загрузка объектов из XML-выгрузки Конфигуратора в информационную базу через ibcmd
  и обновление конфигурации базы данных.

.EXAMPLE
  # отчёт основной конфигурации целиком
  ibcmd-load.ps1 -DbPath C:\Bases\ERP -User Админ -BaseDir C:\Bases\ERP_SRC\cf -Objects Reports\МойОтчет

.EXAMPLE
  # новый заимствованный объект в расширении: нужен родитель (Configuration.xml)
  ibcmd-load.ps1 -DbPath C:\Bases\ERP -User Админ -BaseDir C:\Bases\ERP_SRC\cfe\МоёРасширение -Extension МоёРасширение `
    -Files Configuration.xml,Reports\МойОтчет.xml,Subsystems\Отчеты.xml -BackupDir C:\Temp\bak
#>
param(
    [Parameter(Mandatory = $true)][string]$DbPath,
    # Пусто — без аутентификации (база без пользователей)
    [string]$User = '',
    [string]$Password = '',
    [Parameter(Mandatory = $true)][string]$BaseDir,
    # Объект целиком, путь относительно BaseDir без .xml: Reports\X -> X.xml + все файлы каталога X
    [string[]]$Objects = @(),
    # Отдельные файлы относительно BaseDir: Configuration.xml, Subsystems\Y.xml, Reports\X\Forms\Ф.xml
    [string[]]$Files = @(),
    [string]$Extension = '',
    # Перед импортом сохранить текущую конфигурацию (или расширение) в .cf/.cfe в этот каталог
    [string]$BackupDir = '',
    # Отключить проверку метаданных после импорта. Только с согласия пользователя: см. SKILL.md
    [switch]$NoCheck,
    # Только импорт, без config apply
    [switch]$SkipApply,
    # Показать команды и состав файлов, ничего не выполнять
    [switch]$WhatIf,
    [string]$Ibcmd = ''
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not $Ibcmd) {
    $Ibcmd = Get-ChildItem "$env:ProgramFiles\1cv8\*\bin\ibcmd.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Directory.Parent.Name -replace '[^\d.]', '') } -ErrorAction SilentlyContinue |
        Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $Ibcmd -or -not (Test-Path $Ibcmd)) { Write-Host 'ibcmd.exe не найден, укажите -Ibcmd'; exit 2 }

# powershell -File передаёт массив одной строкой через запятую
$Objects = @($Objects | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Files = @($Files | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$BaseDir = (Resolve-Path $BaseDir).Path.TrimEnd('\')
$list = New-Object System.Collections.Generic.List[string]
foreach ($o in $Objects) {
    $o = $o.TrimEnd('\')
    if (-not (Test-Path (Join-Path $BaseDir "$o.xml"))) { Write-Host "нет файла $o.xml в $BaseDir"; exit 2 }
    $list.Add("$o.xml")
    $dir = Join-Path $BaseDir $o
    if (Test-Path $dir) {
        Get-ChildItem $dir -Recurse -File | ForEach-Object { $list.Add($_.FullName.Substring($BaseDir.Length + 1)) }
    }
}
foreach ($f in $Files) {
    if (-not (Test-Path (Join-Path $BaseDir $f))) { Write-Host "нет файла $f в $BaseDir"; exit 2 }
    $list.Add($f)
}
if ($list.Count -eq 0) { Write-Host 'не заданы -Objects или -Files'; exit 2 }

$auth = @("--db-path=$DbPath")
if ($User) { $auth += @("--user=$User", "--password=$Password") }
$ext = @(); if ($Extension) { $ext = @("--extension=$Extension") }

function Invoke-Ibcmd([string]$Step, [string[]]$IbArgs) {
    $shown = ($IbArgs | ForEach-Object { if ($_ -like '--password=*') { '--password=***' } else { $_ } }) -join ' '
    Write-Host "== $Step"
    Write-Host "   ibcmd $shown"
    if ($WhatIf) { return 0 }
    # Пароль дублируется в stdin: если ibcmd всё же спросит его, он не повиснет на вводе.
    $Password | & $Ibcmd @IbArgs 2>&1 | ForEach-Object { Write-Host "   $_" }
    $code = $LASTEXITCODE
    Write-Host "   exit=$code"
    return $code
}

Write-Host "ibcmd: $Ibcmd"
Write-Host "файлов к импорту: $($list.Count)"
$list | ForEach-Object { Write-Host "   $_" }

if ($BackupDir) {
    if (-not $WhatIf) { New-Item -ItemType Directory -Force $BackupDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $name = if ($Extension) { "$Extension`_$stamp.cfe" } else { "config_$stamp.cf" }
    $code = Invoke-Ibcmd 'резервная копия' (@('infobase', 'config', 'save') + $auth + $ext + @((Join-Path $BackupDir $name)))
    if ($code -ne 0) { Write-Host 'резервная копия не сохранена, загрузка отменена'; exit 1 }
}

$imp = @('infobase', 'config', 'import', 'files') + $auth + $ext + @("--base-dir=$BaseDir", '--partial')
if ($NoCheck) { $imp += '--no-check' }
$code = Invoke-Ibcmd 'импорт' ($imp + $list.ToArray())
if ($code -ne 0) { Write-Host 'импорт не выполнен, база не изменена'; exit 1 }

if ($SkipApply) { Write-Host 'config apply пропущен (-SkipApply): изменения в конфигурации, но не в БД'; exit 0 }

$code = Invoke-Ibcmd 'обновление конфигурации БД' (@('infobase', 'config', 'apply') + $auth + $ext + @('--force'))
if ($code -ne 0) { Write-Host 'config apply не выполнен: конфигурация загружена, но к БД не применена'; exit 1 }
exit 0
