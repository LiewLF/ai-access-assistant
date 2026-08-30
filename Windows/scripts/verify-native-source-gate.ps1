[CmdletBinding()]
param(
    [string] $Configuration = "Release",
    [string] $BuildOutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$windowsRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BuildOutputDirectory)) {
    $BuildOutputDirectory = Join-Path $windowsRoot (
        "src/AIAccessAssistant.Windows/bin/{0}/net10.0-windows10.0.26100.0/win-x64" -f $Configuration)
}

$executable = Join-Path $BuildOutputDirectory "AIAccessAssistant.Windows.exe"
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Native build executable missing: $executable"
}

$bytes = [System.IO.File]::ReadAllBytes($executable)
if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
    throw "Native build executable is not a valid PE file"
}
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
if ($peOffset -lt 0 -or ($peOffset + 26) -gt $bytes.Length) {
    throw "Native build executable contains an invalid PE header offset"
}
if ($bytes[$peOffset] -ne 0x50 -or
    $bytes[$peOffset + 1] -ne 0x45 -or
    $bytes[$peOffset + 2] -ne 0x00 -or
    $bytes[$peOffset + 3] -ne 0x00) {
    throw "Native build executable does not contain a PE signature"
}
$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
$optionalHeaderMagic = [BitConverter]::ToUInt16($bytes, $peOffset + 24)
if ($machine -ne 0x8664 -or $optionalHeaderMagic -ne 0x020B) {
    throw ("Native build executable is not AMD64 PE32+: machine=0x{0:X4} magic=0x{1:X4}" -f $machine, $optionalHeaderMagic)
}

$version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
if ($version.FileVersion -ne "0.12.0.148") {
    throw "Native build FileVersion drifted: $($version.FileVersion)"
}
if (-not $version.ProductVersion.StartsWith("0.12.0+build.148", [StringComparison]::Ordinal)) {
    throw "Native build ProductVersion drifted: $($version.ProductVersion)"
}

$signature = Get-AuthenticodeSignature -LiteralPath $executable
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::NotSigned) {
    throw "Source-gate executable unexpectedly carries a distribution signature: $($signature.Status)"
}

$forbidden = @(Get-ChildItem -LiteralPath $BuildOutputDirectory -Recurse -File | Where-Object {
    $_.Extension -in @(".msix", ".msixbundle", ".appx", ".appxbundle", ".zip", ".dmg") -or
    $_.Name -like "*Setup.exe"
})
if ($forbidden.Count -ne 0) {
    throw "Native source gate generated a package artifact: $($forbidden[0].Name)"
}

Write-Output "WINDOWS_NATIVE_BUILD_IDENTITY=PASS version=0.12.0 build=148 format=PE32+ machine=AMD64 signed=false"
Write-Output "WINDOWS_NATIVE_SOURCE_BOUNDARY=PASS package=not-generated installer=not-generated artifact-upload=not-run runtime-journey=not-claimed"
