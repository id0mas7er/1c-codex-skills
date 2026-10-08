<#
.SYNOPSIS
  Выгрузка конфигурации или расширения информационной базы в XML (формат Конфигуратора) через ibcmd.

.DESCRIPTION
  ibcmd выгружает только в пустой каталог. Если OutDir не пуст, выгрузка идёт в соседний
  каталог <OutDir>.__new, а с ключом -Replace содержимое OutDir заменяется новым. Записи, имя которых
  начинается с точки (.git, .code-index и т.п.), не трогаются.

.EXAMPLE
  ibcmd-export.ps1 -DbPath C:\Bases\ERP -User Админ -OutDir C:\Bases\ERP_SRC\cf -Replace
  ibcmd-export.ps1 -DbPath C:\Bases\ERP -User Админ -Extension МоёРасширение -OutDir C:\Bases\ERP_SRC\cfe\МоёРасширение -Replace

.EXAMPLE
  # отдельные объекты (с дочерними: формы, макеты) — в пустой каталог
  ibcmd-export.ps1 -DbPath C:\Bases\ERP -User Админ -OutDir C:\Temp\check -Objects "Document.ЗаказКлиента,Report.МойОтчет"
#>
param(
    [Parameter(Mandatory = $true)][string]$DbPath,
    # Пусто — без аутентификации (база без пользователей)
    [string]$User = '',
    [string]$Password = '',
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Extension = '',
    [switch]$Replace,
    # Только эти объекты (Document.X, Report.Y, DefinedType.Z …): config export objects --recursive
    [string[]]$Objects = @(),
    # Каталог временных файлов ibcmd (TEMP/TMP)
    [string]$TempDir = '',
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
if ($TempDir) {
    New-Item -ItemType Directory -Force $TempDir | Out-Null
    $env:TEMP = $TempDir; $env:TMP = $TempDir
}

$OutDir = $OutDir.TrimEnd('\')
$target = $OutDir
# ibcmd считает непустым и каталог только со скрытыми записями (.git, .code-index)
$busy = (Test-Path $OutDir) -and @(Get-ChildItem $OutDir -Force).Count -gt 0
if ($busy -and $Objects.Count) { Write-Host "$OutDir не пуст: отдельные объекты выгружаются только в пустой (или новый) каталог"; exit 2 }
if ($busy) {
    if (-not $Replace) { Write-Host "$OutDir не пуст: ibcmd выгружает только в пустой каталог. Добавьте -Replace"; exit 2 }
    $target = "$OutDir.__new"
    if (Test-Path $target) { Write-Host "$target уже существует: остался от прошлой выгрузки, разберитесь с ним"; exit 2 }
}

$ibArgs = @('infobase', 'config', 'export')
if ($Objects.Count) { $ibArgs += 'objects' }
$ibArgs += "--db-path=$DbPath"
if ($User) { $ibArgs += @("--user=$User", "--password=$Password") }
if ($Extension) { $ibArgs += "--extension=$Extension" }
if ($Objects.Count) {
    # --recursive: с формами, макетами и т.п.; --ignore-unresolved-refs: не падать на ссылках на невыгружаемые объекты
    $ibArgs += @("--out=$target", '--recursive', '--ignore-unresolved-refs') + $Objects
} else {
    $ibArgs += $target
}

Write-Host "ibcmd: $Ibcmd"
Write-Host "выгрузка в $target"
$sw = [Diagnostics.Stopwatch]::StartNew()
$Password | & $Ibcmd @ibArgs 2>&1 | ForEach-Object { Write-Host "   $_" }
$code = $LASTEXITCODE
Write-Host ("exit={0}, {1:N0} c" -f $code, $sw.Elapsed.TotalSeconds)
if ($code -ne 0) { exit 1 }

if ($target -ne $OutDir) {
    Get-ChildItem $OutDir -Force | Where-Object { $_.Name -notlike '.*' } | Remove-Item -Recurse -Force
    Get-ChildItem $target -Force | Move-Item -Destination $OutDir
    Remove-Item $target -Force
    Write-Host "содержимое $OutDir заменено"
}
$n = @(Get-ChildItem $OutDir -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.' }).Count
Write-Host "файлов: $n"
exit 0
