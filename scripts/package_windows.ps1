param([string]$Version = '4.1.26', [switch]$InstallerOnly)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$bundle = Join-Path (Get-Location) 'build/windows/x64/runner/Release'
foreach ($file in @('ProxyYou.exe','hiddify-core.dll','libcronet.dll','HiddifyCli.exe',
  'flutter_windows.dll','sqlite3.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','data/app.so','data/icudtl.dat','data/flutter_assets')) {
  if (!(Test-Path (Join-Path $bundle $file))) { throw "В сборке отсутствует $file" }
}
New-Item -ItemType Directory -Force 'out' | Out-Null
foreach ($file in @('ProxyYou.exe','hiddify-core.dll','HiddifyCli.exe','libcronet.dll','flutter_windows.dll','sqlite3.dll')) {
  $reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead((Join-Path $bundle $file)))
  try {
    $reader.BaseStream.Position = 0x3c
    $offset = $reader.ReadInt32()
    $reader.BaseStream.Position = $offset
    if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw "$file не является Windows x64 PE" }
  } finally { $reader.Dispose() }
}
$reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead((Join-Path $bundle 'data/app.so')))
try {
  if ($reader.ReadUInt32() -ne 0x464c457f -or $reader.ReadByte() -ne 2 -or $reader.ReadByte() -ne 1) { throw 'Неверный формат AOT-снимка' }
  $reader.BaseStream.Position = 18
  if ($reader.ReadUInt16() -ne 62) { throw 'AOT-снимок не является x86-64' }
} finally { $reader.Dispose() }
Copy-Item 'LICENSE.md' $bundle -Force
Copy-Item 'WINDOWS.md' $bundle -Force
$artifacts = @()
if (!$InstallerOnly) {
  $archive = "out/ProxyYou-Windows-x64-$Version.zip"
  $packagePaths = @(Get-ChildItem $bundle -File | Where-Object { $_.Extension -in @('.exe','.dll') } | ForEach-Object FullName)
  $packagePaths += @((Join-Path $bundle 'LICENSE.md'), (Join-Path $bundle 'WINDOWS.md'), (Join-Path $bundle 'data'))
  Compress-Archive -LiteralPath $packagePaths -DestinationPath $archive -Force
  $artifacts += $archive
}
$compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (!$compiler) {
  $innoPath = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
  if (Test-Path $innoPath) { $compiler = Get-Item $innoPath }
}
if ($compiler) {
  $compilerPath = if ($compiler -is [System.Management.Automation.CommandInfo]) { $compiler.Source } else { $compiler.FullName }
  & $compilerPath "/DAppVersion=$Version" "/DBuildRoot=$bundle" "windows/packaging/proxyyou.iss"
  if ($LASTEXITCODE -ne 0) { throw 'Ошибка создания установщика.' }
  $artifacts += "out/ProxyYou-Windows-x64-$Version-Setup.exe"
} elseif ($InstallerOnly) {
  throw 'Для создания EXE требуется Inno Setup 6 (ISCC.exe).'
} else {
  Write-Output 'Portable ZIP создан. Для установщика требуется Inno Setup 6 (ISCC.exe).'
}
Get-FileHash -LiteralPath $artifacts -Algorithm SHA256 | ForEach-Object {
  "$($_.Hash.ToLower())  $(Split-Path $_.Path -Leaf)"
} | Set-Content "out/ProxyYou-Windows-x64-$Version.sha256" -Encoding ASCII
