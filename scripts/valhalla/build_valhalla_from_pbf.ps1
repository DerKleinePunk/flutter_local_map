param(
    [Parameter(Mandatory = $true)]
    [string]$InputPbf,

    [Parameter(Mandatory = $true)]
    [string]$Output,

    # Quotes required: -Bbox "8.9,50.22,9.9,50.85"  (west,south,east,north)
    [string]$Bbox,
    [string]$Region = "region",
    [string]$Image = "ghcr.io/gis-ops/docker-valhalla/valhalla:latest"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Resolve-Path -Path $Path).Path
}

if (-not (Test-Path -LiteralPath $InputPbf -PathType Leaf)) {
    throw "Input file not found: $InputPbf"
}

if (-not (Test-Path -LiteralPath $Output)) {
    New-Item -ItemType Directory -Path $Output -Force | Out-Null
}

$OutputFull = Resolve-FullPath -Path $Output
$WorkDir = Join-Path $OutputFull "work"
if (-not (Test-Path -LiteralPath $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

$ExtractPbf = Join-Path $WorkDir ("{0}.osm.pbf" -f $Region)

if ($Bbox) {
    if (-not (Get-Command osmium -ErrorAction SilentlyContinue)) {
        throw "--Bbox requires 'osmium' on PATH. Install osmium-tool or run without --Bbox."
    }

    Write-Host "[1/4] Creating bounded extract from input with bbox=$Bbox"
    & osmium extract -b $Bbox $InputPbf -o $ExtractPbf --overwrite
    if ($LASTEXITCODE -ne 0) {
        throw "osmium extract failed."
    }
}
else {
    Write-Host "[1/4] Using input extract directly"
    Copy-Item -LiteralPath $InputPbf -Destination $ExtractPbf -Force
}

# Keep a root-level PBF so the GIS-OPS runtime image can auto-build if no prebuilt tiles exist.
Copy-Item -LiteralPath $ExtractPbf -Destination (Join-Path $OutputFull ("{0}.osm.pbf" -f $Region)) -Force
$TransitDir = Join-Path $OutputFull "transit_tiles"
if (-not (Test-Path -LiteralPath $TransitDir)) {
    New-Item -ItemType Directory -Path $TransitDir -Force | Out-Null
}

# Remove broken/stale config files. This image generates/updates valhalla.json itself.
$ConfigPath = Join-Path $OutputFull "valhalla.json"
if ((Test-Path -LiteralPath $ConfigPath -PathType Leaf) -and ((Get-Item -LiteralPath $ConfigPath).Length -eq 0)) {
    Remove-Item -LiteralPath $ConfigPath -Force
}

if ((Test-Path -LiteralPath (Join-Path $OutputFull "valhalla_tiles.tar") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $OutputFull "valhalla_tiles") -PathType Container)) {
    Write-Host "[2/2] Prebuilt routing tiles already exist in $OutputFull"
}
else {
    Write-Host "[2/2] Runtime input prepared. Start the container to let GIS-OPS build tiles from ${Region}.osm.pbf"
}

Write-Host "Done"
Write-Host "Prepared Valhalla runtime directory: $OutputFull"
Write-Host "Files in output: ${Region}.osm.pbf, optional valhalla.json, optional valhalla_tiles.tar, admins.sqlite, timezones.sqlite"
