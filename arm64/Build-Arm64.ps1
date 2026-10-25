<#
.SYNOPSIS
    Builds an experimental ARM64 NppMenuSearch.dll by re-assembling the x64 build's IL for ARM64.

.DESCRIPTION
    UnmanagedExports only targets x86 and x64. But the IL it produces is the same for every 64-bit platform,
    and the .NET Framework IL assembler (ilasm) can emit ARM64 images. So this script:
      1. builds the normal Release|x64 plugin (unless -NoBuild),
      2. disassembles it with ildasm (keeping the .vtfixup/.export directives UnmanagedExports added),
      3. re-assembles it with "ilasm /DLL /ARM64 /PE64",
      4. checks the result is an ARM64 image,
      5. copies it and the language files to NppMenuSearch\bin\ARM64\Release\.
    With -Install it also copies them into Notepad++'s plugins folder.

    Works on an x64 or an ARM64 machine with Visual Studio 2022 (MSBuild) and the .NET Framework 4.8 SDK tools (ildasm).
    See arm64\README.md for the plan and the test checklist.

.PARAMETER NoBuild
    Use the existing NppMenuSearch\bin\x64\Release\NppMenuSearch.dll instead of building it.

.PARAMETER Install
    Copy the ARM64 build into <NppDir>\plugins\NppMenuSearch\. Needs admin rights for Program Files.
    If Notepad++ is running, the old DLL is renamed to NppMenuSearch.dll.old (restart Notepad++ to load the new one).

.PARAMETER NppDir
    Notepad++ folder for -Install. Default: C:\Program Files\Notepad++
#>
param(
    [switch]$NoBuild,
    [switch]$Install,
    [string]$NppDir = 'C:\Program Files\Notepad++'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$x64Dir = Join-Path $repo 'NppMenuSearch\bin\x64\Release'
$outDir = Join-Path $repo 'NppMenuSearch\bin\ARM64\Release'
$ilDir = Join-Path $repo 'NppMenuSearch\obj\ARM64\il'

function Find-First([string[]]$patterns, [string]$what) {
    foreach ($p in $patterns) {
        $hit = Get-ChildItem $p -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "Could not find $what. Looked in:`n  " + ($patterns -join "`n  ")
}

function Get-PEMachine([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    return [BitConverter]::ToUInt16($bytes, $pe + 4)
}

# 1. Build Release|x64
if (-not $NoBuild) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    if (-not $msbuild) { throw 'MSBuild not found (is Visual Studio 2022 installed?)' }
    Write-Host "Building Release|x64 with $msbuild"
    & $msbuild (Join-Path $repo 'NppMenuSearch.sln') -t:restore -p:RestorePackagesConfig=true -v:q -nologo
    & $msbuild (Join-Path $repo 'NppMenuSearch.sln') -p:Configuration=Release -p:Platform=x64 -v:m -nologo
    if ($LASTEXITCODE) { throw "x64 build failed ($LASTEXITCODE)" }
}
$x64Dll = Join-Path $x64Dir 'NppMenuSearch.dll'
if (-not (Test-Path $x64Dll)) { throw "$x64Dll not found. Build Release|x64 first, or drop -NoBuild." }

# 2. Disassemble
$ildasm = Find-First @(
    "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows\*\bin\NETFX 4.8* Tools\x64\ildasm.exe",
    "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows\*\bin\NETFX 4.8* Tools\ildasm.exe",
    "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows\*\bin\NETFX 4.* Tools\ildasm.exe"
) 'ildasm.exe (install the ".NET Framework 4.8 SDK" / "4.8 targeting pack" Visual Studio component)'
if (Test-Path $ilDir) { Get-ChildItem $ilDir | Remove-Item -Force }
New-Item -ItemType Directory -Force $ilDir | Out-Null
Write-Host "Disassembling with $ildasm"
& $ildasm /nobar /linenum "/out=$ilDir\NppMenuSearch.il" $x64Dll
if ($LASTEXITCODE) { throw "ildasm failed ($LASTEXITCODE)" }
if (-not (Select-String -Path "$ilDir\NppMenuSearch.il" -Pattern '\.export \[' -Quiet)) {
    throw 'The x64 DLL has no .export directives. Did UnmanagedExports run?'
}

# 3. Re-assemble for ARM64 (ilasm picks up the .resources files from the current directory)
$ilasm = Find-First @(
    "$env:windir\Microsoft.NET\FrameworkArm64\v4.0.30319\ilasm.exe",
    "$env:windir\Microsoft.NET\Framework64\v4.0.30319\ilasm.exe"
) 'ilasm.exe (.NET Framework 4.x)'
New-Item -ItemType Directory -Force $outDir | Out-Null
$outDll = Join-Path $outDir 'NppMenuSearch.dll'
Write-Host "Assembling ARM64 image with $ilasm"
Push-Location $ilDir
try {
    & $ilasm /nologo /quiet /dll /arm64 /pe64 /resource=NppMenuSearch.res "/output=$outDll" NppMenuSearch.il
    if ($LASTEXITCODE) { throw "ilasm failed ($LASTEXITCODE)" }
} finally { Pop-Location }

# 4. Check
$machine = Get-PEMachine $outDll
if ($machine -ne 0xAA64) { throw ('Output is not ARM64 (machine 0x{0:X4})' -f $machine) }
Write-Host ('OK: {0} is ARM64 (machine 0xAA64), {1:N0} bytes' -f $outDll, (Get-Item $outDll).Length)

# 5. Language files
Copy-Item (Join-Path $x64Dir 'NppMenuSearch.dll.*.xml') $outDir -Force

if ($Install) {
    $plugDir = Join-Path $NppDir 'plugins\NppMenuSearch'
    $nppExe = Join-Path $NppDir 'notepad++.exe'
    if (Test-Path $nppExe) {
        $nppMachine = Get-PEMachine $nppExe
        if ($nppMachine -ne 0xAA64) { Write-Warning ('{0} is not the ARM64 build (machine 0x{1:X4}). It cannot load this DLL.' -f $nppExe, $nppMachine) }
    }
    New-Item -ItemType Directory -Force $plugDir | Out-Null
    $target = Join-Path $plugDir 'NppMenuSearch.dll'
    if (Test-Path $target) {
        if (Test-Path "$target.old") { Remove-Item "$target.old" -Force }
        Rename-Item $target 'NppMenuSearch.dll.old'   # works even while Notepad++ has it loaded
    }
    Copy-Item (Join-Path $outDir '*') $plugDir -Force
    Write-Host "Installed to $plugDir. Restart Notepad++ to load it."
}
