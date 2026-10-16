$ErrorActionPreference = 'Stop'
$MiB = 1MB
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseScript = Join-Path $ScriptDir 'manage_logs_windows.ps1'

if (-not (Test-Path -LiteralPath $BaseScript -PathType Leaf)) {
    throw "Main Windows script not found: $BaseScript"
}
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    throw 'tar.exe was not found. These tests need the Windows tar utility.'
}

$XzCommand = Get-Command xz.exe -ErrorAction SilentlyContinue
if ($XzCommand) {
    $XzExe = $XzCommand.Source
}
else {
    $NearbyXz = Join-Path $ScriptDir 'xz.exe'
    if (Test-Path -LiteralPath $NearbyXz -PathType Leaf) {
        $XzExe = $NearbyXz
    }
    else {
        throw 'Test 5 requires xz.exe. Install XZ Utils and put xz.exe on PATH or next to the Windows scripts.'
    }
}

$WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('lab1_windows_tests_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $WorkDir | Out-Null
$OriginalCompression = $env:LAB1_MAX_COMPRESSION

function Fail([string]$Message) { throw "FAIL: $Message" }

function New-ZeroFile([string]$Path, [int]$SizeMiB) {
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $Stream.SetLength([long]$SizeMiB * $MiB) }
    finally { $Stream.Dispose() }
}

function Set-TestDate([string]$Path, [string]$DateString) {
    [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::Parse($DateString).ToUniversalTime())
}

function New-TestEnvironment([string]$Name, [hashtable]$Files) {
    $Root = Join-Path $WorkDir $Name
    $Log = Join-Path $Root 'log'
    $Backup = Join-Path $Root 'backup'
    New-Item -ItemType Directory -Path $Log, $Backup -Force | Out-Null
    foreach ($Entry in $Files.GetEnumerator()) {
        New-ZeroFile (Join-Path $Log $Entry.Key) ([int]$Entry.Value)
    }
    return [pscustomobject]@{ Root = $Root; Log = $Log; Backup = $Backup }
}

function Assert-MinimumSize([string]$LogDir) {
    [long]$Size = 0
    foreach ($File in @(Get-ChildItem -LiteralPath $LogDir -File -Recurse -Force)) {
        $Size += [long]$File.Length
    }
    if ($Size -lt (500L * $MiB)) { Fail "test setup: $LogDir is smaller than 500 MiB" }
}

function Get-Archives([string]$BackupDir, [string]$Pattern = '*.tar.*') {
    return @(Get-ChildItem -LiteralPath $BackupDir -File -Filter $Pattern)
}

function Get-ArchiveContents([string]$ArchivePath) {
    if ($ArchivePath.EndsWith('.tar.lzma', [StringComparison]::OrdinalIgnoreCase)) {
        $TarPath = $ArchivePath.Substring(0, $ArchivePath.Length - '.lzma'.Length)
        Remove-Item -LiteralPath $TarPath -Force -ErrorAction SilentlyContinue

        & $XzExe --format=lzma --test $ArchivePath *> $null
        if ($LASTEXITCODE -ne 0) { Fail "LZMA stream is invalid: $ArchivePath" }

        & $XzExe --format=lzma --decompress --keep --force $ArchivePath *> $null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $TarPath -PathType Leaf)) {
            Remove-Item -LiteralPath $TarPath -Force -ErrorAction SilentlyContinue
            Fail "could not decompress LZMA archive: $ArchivePath"
        }

        try {
            $Lines = @(& tar.exe -tf $TarPath 2>&1)
            if ($LASTEXITCODE -ne 0) { Fail "tar payload cannot be read: $TarPath. $($Lines -join ' ')" }
            return $Lines | ForEach-Object { ("$($_)".Trim() -replace '^[.][\\/]', '') }
        }
        finally {
            Remove-Item -LiteralPath $TarPath -Force -ErrorAction SilentlyContinue
        }
    }

    $Lines = @(& tar.exe -tf $ArchivePath 2>&1)
    if ($LASTEXITCODE -ne 0) { Fail "archive cannot be read: $ArchivePath. $($Lines -join ' ')" }
    return $Lines | ForEach-Object { ("$($_)".Trim() -replace '^[.][\\/]', '') }
}

function Run-Base([pscustomobject]$Env, [int]$Threshold, [int]$CapacityMiB) {
    & $BaseScript $Env.Log $Threshold $CapacityMiB $Env.Backup | Out-Null
}

try {
    # Test 1: 600 MiB is below the threshold (700 MiB).
    $T = New-TestEnvironment 'test1' @{ 'recent.log' = 600 }
    Set-TestDate (Join-Path $T.Log 'recent.log') '2025-01-01'
    Assert-MinimumSize $T.Log
    Run-Base $T 70 1000
    if (-not (Test-Path -LiteralPath (Join-Path $T.Log 'recent.log'))) { Fail 'test 1: source file should remain' }
    if ((Get-Archives $T.Backup).Count -ne 0) { Fail 'test 1: no archive should be created' }
    Write-Host 'PASS 1/5: below threshold, no archive created.'
    Remove-Item -LiteralPath $T.Root -Recurse -Force

    # Test 2: 900 MiB; the oldest file is archived and removed.
    $T = New-TestEnvironment 'test2' @{ 'old.log' = 300; 'middle.log' = 300; 'new.log' = 300 }
    Set-TestDate (Join-Path $T.Log 'old.log') '2020-01-01'
    Set-TestDate (Join-Path $T.Log 'middle.log') '2021-01-01'
    Set-TestDate (Join-Path $T.Log 'new.log') '2022-01-01'
    Assert-MinimumSize $T.Log
    Run-Base $T 70 1000
    if (Test-Path -LiteralPath (Join-Path $T.Log 'old.log')) { Fail 'test 2: oldest file should be deleted' }
    if (-not (Test-Path -LiteralPath (Join-Path $T.Log 'middle.log')) -or -not (Test-Path -LiteralPath (Join-Path $T.Log 'new.log'))) { Fail 'test 2: newer files should remain' }
    $Archives = Get-Archives $T.Backup '*.tar.gz'
    if ($Archives.Count -ne 1) { Fail 'test 2: expected one .tar.gz archive' }
    $Contents = Get-ArchiveContents $Archives[0].FullName
    if ($Contents -notcontains 'old.log') { Fail 'test 2: archive must contain old.log' }
    if ($Contents -contains 'middle.log') { Fail 'test 2: middle.log should not be archived' }
    Write-Host 'PASS 2/5: over threshold, oldest file archived and removed.'
    Remove-Item -LiteralPath $T.Root -Recurse -Force

    # Test 3: a custom 50% threshold.
    $T = New-TestEnvironment 'test3' @{ 'old.log' = 200; 'middle.log' = 200; 'new.log' = 250 }
    Set-TestDate (Join-Path $T.Log 'old.log') '2020-01-01'
    Set-TestDate (Join-Path $T.Log 'middle.log') '2021-01-01'
    Set-TestDate (Join-Path $T.Log 'new.log') '2022-01-01'
    Assert-MinimumSize $T.Log
    Run-Base $T 50 1000
    if (Test-Path -LiteralPath (Join-Path $T.Log 'old.log')) { Fail 'test 3: oldest file should be deleted' }
    if (-not (Test-Path -LiteralPath (Join-Path $T.Log 'middle.log')) -or -not (Test-Path -LiteralPath (Join-Path $T.Log 'new.log'))) { Fail 'test 3: newer files should remain' }
    $Archives = Get-Archives $T.Backup '*.tar.gz'
    if ($Archives.Count -ne 1) { Fail 'test 3: expected one .tar.gz archive' }
    $Contents = Get-ArchiveContents $Archives[0].FullName
    if ($Contents -notcontains 'old.log') { Fail 'test 3: archive must contain old.log' }
    Write-Host 'PASS 3/5: custom 50% threshold is respected.'
    Remove-Item -LiteralPath $T.Root -Recurse -Force

    # Test 4: exactly at the threshold must not start archiving.
    $T = New-TestEnvironment 'test4' @{ 'exact-limit.log' = 700 }
    Set-TestDate (Join-Path $T.Log 'exact-limit.log') '2024-01-01'
    Assert-MinimumSize $T.Log
    Run-Base $T 70 1000
    if (-not (Test-Path -LiteralPath (Join-Path $T.Log 'exact-limit.log'))) { Fail 'test 4: source file should remain at exact threshold' }
    if ((Get-Archives $T.Backup).Count -ne 0) { Fail 'test 4: no archive should be created at exact threshold' }
    Write-Host 'PASS 4/5: exact threshold does not trigger archiving.'
    Remove-Item -LiteralPath $T.Root -Recurse -Force

    # Test 5: the environment variable must request a valid LZMA-compressed tar.
    $T = New-TestEnvironment 'test5' @{ 'old.log' = 300; 'middle.log' = 300; 'new.log' = 300 }
    Set-TestDate (Join-Path $T.Log 'old.log') '2020-01-01'
    Set-TestDate (Join-Path $T.Log 'middle.log') '2021-01-01'
    Set-TestDate (Join-Path $T.Log 'new.log') '2022-01-01'
    Assert-MinimumSize $T.Log
    $env:LAB1_MAX_COMPRESSION = '1'
    Run-Base $T 70 1000
    if (Test-Path -LiteralPath (Join-Path $T.Log 'old.log')) { Fail 'test 5: oldest file should be deleted' }
    if (-not (Test-Path -LiteralPath (Join-Path $T.Log 'middle.log')) -or -not (Test-Path -LiteralPath (Join-Path $T.Log 'new.log'))) { Fail 'test 5: newer files should remain' }
    $Archives = Get-Archives $T.Backup '*.tar.lzma'
    if ($Archives.Count -ne 1) { Fail 'test 5: expected one .tar.lzma archive' }
    $Contents = Get-ArchiveContents $Archives[0].FullName
    if ($Contents -notcontains 'old.log') { Fail 'test 5: LZMA archive must contain old.log' }
    if ($Contents -contains 'middle.log') { Fail 'test 5: middle.log should not be in the archive' }
    Write-Host 'PASS 5/5: LAB1_MAX_COMPRESSION=1 creates a valid LZMA archive.'

    Write-Host 'All 5 Windows tests passed.'
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    if ($null -eq $OriginalCompression) { Remove-Item Env:LAB1_MAX_COMPRESSION -ErrorAction SilentlyContinue }
    else { $env:LAB1_MAX_COMPRESSION = $OriginalCompression }
    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}
