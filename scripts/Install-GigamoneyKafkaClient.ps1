param(
    [string]$DestinationPath = '',
    [string]$ConfluentKafkaVersion = '2.15.0'
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$projectRoot = Split-Path -Parent $scriptRoot
$destination = if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    Join-Path $projectRoot 'work\kafka-client'
} elseif ([System.IO.Path]::IsPathRooted($DestinationPath)) {
    $DestinationPath
} else {
    Join-Path $projectRoot $DestinationPath
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Install-NuGetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $normalizedId = $Id.ToLowerInvariant()
    $normalizedVersion = $Version.ToLowerInvariant()
    $packageDir = Join-Path $destination "packages\$normalizedId.$normalizedVersion"
    $marker = Join-Path $packageDir '.installed'
    if (Test-Path -LiteralPath $marker) {
        Write-Host "Kafka dependency already installed: $Id $Version"
        return
    }

    New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
    $packageFile = Join-Path $destination "$normalizedId.$normalizedVersion.nupkg"
    $url = "https://api.nuget.org/v3-flatcontainer/$normalizedId/$normalizedVersion/$normalizedId.$normalizedVersion.nupkg"

    Write-Host "Downloading $Id $Version from NuGet."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $packageFile
        [System.IO.Compression.ZipFile]::ExtractToDirectory($packageFile, $packageDir)
        Set-Content -LiteralPath $marker -Value "$Id $Version" -Encoding ASCII
    } catch {
        throw "Could not install Kafka dependency $Id $Version from $url. $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $packageFile) {
            Remove-Item -LiteralPath $packageFile -Force
        }
    }
}

New-Item -ItemType Directory -Force -Path $destination | Out-Null

# These are the .NET Framework dependency versions declared by Confluent.Kafka 2.15.0.
# Keep the Confluent.Kafka and librdkafka.redist versions aligned.
Install-NuGetPackage -Id 'System.Runtime.CompilerServices.Unsafe' -Version '6.1.2'
Install-NuGetPackage -Id 'System.Buffers' -Version '4.6.1'
Install-NuGetPackage -Id 'System.Numerics.Vectors' -Version '4.6.1'
Install-NuGetPackage -Id 'System.Memory' -Version '4.6.3'
Install-NuGetPackage -Id 'librdkafka.redist' -Version $ConfluentKafkaVersion
Install-NuGetPackage -Id 'Confluent.Kafka' -Version $ConfluentKafkaVersion

Write-Host "Kafka client installed at $destination"
