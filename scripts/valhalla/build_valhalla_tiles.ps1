param(
    [Parameter(Mandatory = $true)]
    [string]$Data,

    [string]$Name  = "valhalla-build",
    [string]$Image = "ghcr.io/gis-ops/docker-valhalla/valhalla:latest"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Data -PathType Container)) {
    throw "Data directory not found: $Data"
}

$DataFull = (Resolve-Path -Path $Data).Path

# Voraussetzungen pruefen
$hasPbf = (Get-ChildItem -LiteralPath $DataFull -Filter *.osm.pbf -File -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
if (-not $hasPbf) {
    throw "Keine .osm.pbf-Datei in $DataFull gefunden. Tile-Build nicht moeglich."
}

$TransitDir = Join-Path $DataFull "transit_tiles"
if (-not (Test-Path -LiteralPath $TransitDir)) {
    New-Item -ItemType Directory -Path $TransitDir -Force | Out-Null
}

$ConfigPath = Join-Path $DataFull "valhalla.json"
if ((Test-Path -LiteralPath $ConfigPath -PathType Leaf) -and ((Get-Item -LiteralPath $ConfigPath).Length -eq 0)) {
    Write-Host "Removing empty valhalla.json so the container can regenerate it"
    Remove-Item -LiteralPath $ConfigPath -Force
}

Write-Host "Stopping leftover build container (if any): $Name"
try { & docker rm -f $Name 2>&1 | Out-Null } catch { <# container did not exist, ignore #> }

Write-Host "Pulling Docker image: $Image"
& docker pull $Image
if ($LASTEXITCODE -ne 0) {
    throw "Failed to pull Docker image: $Image"
}

Write-Host ""
Write-Host "Starting Valhalla tile build from PBF in $DataFull"
Write-Host "(serve_tiles=False  ->  Container exits when build is done)"
Write-Host ""

# Im Vordergrund laufen lassen: kein -d, damit der Output sichtbar ist
& docker run --rm `
    --name $Name `
    -v "${DataFull}:/custom_files" `
    -e use_tiles_ignore_pbf=False `
    -e force_rebuild=True `
    -e build_admins=True `
    -e build_time_zones=True `
    -e serve_tiles=False `
    $Image

if ($LASTEXITCODE -ne 0) {
    throw "Valhalla tile build failed (exit code $LASTEXITCODE)."
}

Write-Host ""
Write-Host "Tile build finished. Output in: $DataFull"
Write-Host "Starte jetzt den Server mit:"
Write-Host "  .\scripts\valhalla\run_valhalla_server.ps1 -Data ""$Data"""
