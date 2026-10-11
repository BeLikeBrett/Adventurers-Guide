$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$guideAddon = Split-Path -Parent $PSScriptRoot
$guideBase = Join-Path $env:LOCALAPPDATA 'AdventurersGuide'
New-Item -ItemType Directory -Force -Path $guideBase | Out-Null
$guideNode = $null
$systemNode = Get-Command node.exe -ErrorAction SilentlyContinue
if ($systemNode) {
  & $systemNode.Source -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||a===22&&b>=2?0:1)'
  if ($LASTEXITCODE -eq 0) { $guideNode = $systemNode.Source }
}
if (-not $guideNode) {
  $guideVersion = 'v22.23.3'
  $guideArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
  $guideFolder = "node-$guideVersion-win-$guideArch"
  $guideRuntime = Join-Path $guideBase 'runtime'
  $guideNode = Join-Path $guideRuntime "$guideFolder\node.exe"
  if (-not (Test-Path $guideNode)) {
    Write-Host 'Preparing Adventurer’s Guide: downloading Node.js from nodejs.org…'
    New-Item -ItemType Directory -Force -Path $guideRuntime | Out-Null
    $guideTemp = Join-Path $guideRuntime ([Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $guideTemp | Out-Null
    try {
      $guideArchive = "$guideFolder.zip"
      $guideZip = Join-Path $guideTemp $guideArchive
      Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/$guideVersion/$guideArchive" -OutFile $guideZip
      $manifest = (Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/$guideVersion/SHASUMS256.txt").Content
      $expected = ($manifest -split "`n" | Where-Object { $_.Trim().EndsWith("  $guideArchive") } | Select-Object -First 1).Split(' ')[0]
      if (-not $expected -or (Get-FileHash $guideZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected.ToLowerInvariant()) { throw 'The download checksum did not match. Please retry.' }
      Expand-Archive -Path $guideZip -DestinationPath $guideRuntime -Force
    } finally { Remove-Item $guideTemp -Recurse -Force }
  }
}
$setupPath = Join-Path $guideAddon 'companion\bridge\setup.mjs'
Start-Process -FilePath $guideNode -ArgumentList @(('"'+$setupPath+'"')) -WorkingDirectory $guideAddon -WindowStyle Hidden
Write-Host 'Adventurer’s Guide setup is opening in your browser.'
