param(
    [Parameter(Mandatory = $true)]
    [string]$Data,

    [int]$Port = 8002,
    [string]$Name = "valhalla-local",
    [string]$Image = "ghcr.io/gis-ops/docker-valhalla/valhalla:latest"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Data -PathType Container)) {
    throw "Data directory not found: $Data"
}

$DataFull = (Resolve-Path -Path $Data).Path
$ConfigPath = Join-Path $DataFull "valhalla.json"
$TransitDir = Join-Path $DataFull "transit_tiles"
if (-not (Test-Path -LiteralPath $TransitDir)) {
    New-Item -ItemType Directory -Path $TransitDir -Force | Out-Null
}
if ((Test-Path -LiteralPath $ConfigPath -PathType Leaf) -and ((Get-Item -LiteralPath $ConfigPath).Length -eq 0)) {
    Write-Host "Removing empty valhalla.json so the container can regenerate it"
    Remove-Item -LiteralPath $ConfigPath -Force
}

Write-Host "Stopping existing container (if any): $Name"
& docker rm -f $Name | Out-Null

${useTilesIgnorePbf} = "False"
${forceRebuild} = "False"

${hasTileTar} = Test-Path -LiteralPath (Join-Path $DataFull "valhalla_tiles.tar") -PathType Leaf
${hasTileDir} = Test-Path -LiteralPath (Join-Path $DataFull "valhalla_tiles") -PathType Container
${hasPbf} = (Get-ChildItem -LiteralPath $DataFull -Filter *.osm.pbf -File -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0

if ($hasTileTar -or $hasTileDir) {
    ${useTilesIgnorePbf} = "True"
    ${forceRebuild} = "False"
}
elseif ($hasPbf) {
    ${useTilesIgnorePbf} = "False"
    ${forceRebuild} = "True"
}
else {
    throw "Weder prebuilt tiles noch .osm.pbf in $DataFull gefunden."
}

Write-Host "Starting Valhalla on http://127.0.0.1:$Port"
& docker run -d `
    --name $Name `
    --restart unless-stopped `
    -p "${Port}:8002" `
    -v "${DataFull}:/custom_files" `
    -e use_tiles_ignore_pbf=${useTilesIgnorePbf} `
    -e force_rebuild=${forceRebuild} `
    -e build_admins=True `
    -e build_time_zones=True `
    -e serve_tiles=True `
    $Image

if ($LASTEXITCODE -ne 0) {
    throw "Failed to start Valhalla container."
}

Write-Host "Container started: $Name"
Write-Host "Test route with PowerShell:"
Write-Host '$body = @{ locations = @(@{ lat = 50.55; lon = 9.68 }, @{ lat = 50.56; lon = 9.70 }); costing = "auto" } | ConvertTo-Json -Depth 5'
Write-Host "Invoke-RestMethod -Uri http://127.0.0.1:$Port/route -Method Post -ContentType 'application/json' -Body `$body"
