param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$LogDir,
    [Parameter(Position = 1)]
    [ValidateRange(0, 100)]
    [int]$Threshold = 70,
    [Parameter(Position = 2)]
    [ValidateRange(1, 2147483647)]
    [long]$CapacityMiB = 1024,
    [Parameter(Position = 3)]
    [string]$BackupDir = (Join-Path $HOME 'backup')
)

$ErrorActionPreference = 'Stop'
$MiB = 1MB

try {
    if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
        throw "Log directory does not exist: $LogDir"
    }

    $LogPath = (Resolve-Path -LiteralPath $LogDir).Path
    $LogRoot = [IO.Path]::GetPathRoot($LogPath)
    if ($LogPath.Length -gt $LogRoot.Length) { $LogPath = $LogPath.TrimEnd('\') }

    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $BackupPath = (Resolve-Path -LiteralPath $BackupDir).Path
    $BackupRoot = [IO.Path]::GetPathRoot($BackupPath)
    if ($BackupPath.Length -gt $BackupRoot.Length) { $BackupPath = $BackupPath.TrimEnd('\') }

    if ($BackupPath.Equals($LogPath, [StringComparison]::OrdinalIgnoreCase) -or
        $BackupPath.StartsWith($LogPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Backup directory must not be the log directory or a subdirectory of it.'
    }

    $TarCommand = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $TarCommand) {
        $TarCommand = Get-Command tar -ErrorAction SilentlyContinue
    }
    if (-not $TarCommand) {
        throw 'tar.exe was not found. Use a current Windows 10/11 installation or install a compatible tar utility.'
    }
    $TarExe = $TarCommand.Source

    # Windows' built-in tar.exe may not support --lzma. For this mode,
    # use xz.exe with --format=lzma, which writes the standard LZMA stream.
    $XzExe = $null
    $XzCommand = Get-Command xz.exe -ErrorAction SilentlyContinue
    if ($XzCommand) {
        $XzExe = $XzCommand.Source
    }
    else {
        $NearbyXz = Join-Path $PSScriptRoot 'xz.exe'
        if (Test-Path -LiteralPath $NearbyXz -PathType Leaf) { $XzExe = $NearbyXz }
    }

    $Files = @(Get-ChildItem -LiteralPath $LogPath -File -Recurse -Force)
    [long]$UsedBytes = 0
    foreach ($File in $Files) { $UsedBytes += [long]$File.Length }

    [long]$CapacityBytes = $CapacityMiB * $MiB
    [long]$TargetBytes = [math]::Floor($CapacityBytes * $Threshold / 100)
    $UsagePercent = [math]::Round(($UsedBytes * 100.0 / $CapacityBytes), 1)

    Write-Output "Log directory: $LogPath"
    Write-Output ("Usage: {0:N1} MiB of {1} MiB ({2}%); threshold: {3}%." -f ($UsedBytes / $MiB), $CapacityMiB, $UsagePercent, $Threshold)

    if (($UsedBytes * 100) -le ($CapacityBytes * $Threshold)) {
        Write-Output 'Threshold not exceeded. Nothing to archive.'
        return
    }

    $Selected = @()
    [long]$SelectedBytes = 0
    foreach ($File in ($Files | Sort-Object LastWriteTimeUtc, FullName)) {
        $Relative = $File.FullName.Substring($LogPath.Length).TrimStart('\').Replace('\', '/')
        $Selected += [pscustomobject]@{
            FullName = $File.FullName
            RelativePath = './' + $Relative
            Length = [long]$File.Length
        }
        $SelectedBytes += [long]$File.Length
        if (($UsedBytes - $SelectedBytes) -le $TargetBytes) { break }
    }

    if ($Selected.Count -eq 0) {
        throw 'Usage is over the threshold, but no files could be selected.'
    }

    $Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $UseLzma = ($env:LAB1_MAX_COMPRESSION -eq '1')
    if ($UseLzma) {
        if (-not $XzExe) {
            throw 'LAB1_MAX_COMPRESSION=1 requires xz.exe. Install XZ Utils and put xz.exe on PATH or next to manage_logs_windows.ps1. Windows tar.exe on this computer does not support --lzma.'
        }
        $ArchivePath = Join-Path $BackupPath ("logs_{0}_{1}.tar.lzma" -f $Stamp, $PID)
        $TarTempPath = $ArchivePath.Substring(0, $ArchivePath.Length - '.lzma'.Length)
        $TarArgs = @('-cf', $TarTempPath)
        $CompressionName = 'LZMA'
    }
    else {
        $ArchivePath = Join-Path $BackupPath ("logs_{0}_{1}.tar.gz" -f $Stamp, $PID)
        $TarTempPath = $null
        $TarArgs = @('-czf', $ArchivePath)
        $CompressionName = 'gzip'
    }
    foreach ($Entry in $Selected) { $TarArgs += $Entry.RelativePath }

    Write-Output ("Archiving {0} oldest file(s), total {1:N1} MiB using {2}..." -f $Selected.Count, ($SelectedBytes / $MiB), $CompressionName)

    Push-Location -LiteralPath $LogPath
    try {
        & $TarExe @TarArgs
        if ($LASTEXITCODE -ne 0) { throw "tar exited with code $LASTEXITCODE" }

        if ($UseLzma) {
            # xz uses the original LZMA container when --format=lzma is supplied.
            & $XzExe --format=lzma --force $TarTempPath
            if ($LASTEXITCODE -ne 0) { throw "xz.exe exited with code $LASTEXITCODE while compressing with LZMA" }
            if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
                throw 'xz.exe did not create the expected .tar.lzma archive.'
            }
        }
    }
    catch {
        if ($TarTempPath) { Remove-Item -LiteralPath $TarTempPath -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        Pop-Location
    }

    if ($UseLzma) {
        # Validate the LZMA stream, then decompress a temporary .tar for tar validation.
        & $XzExe --format=lzma --test $ArchivePath *> $null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
            throw 'LZMA archive validation failed. Source files were not deleted.'
        }
        & $XzExe --format=lzma --decompress --keep --force $ArchivePath *> $null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $TarTempPath -PathType Leaf)) {
            Remove-Item -LiteralPath $TarTempPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
            throw 'Could not decompress the LZMA archive for validation. Source files were not deleted.'
        }
        & $TarExe -tf $TarTempPath *> $null
        $TarValidationExit = $LASTEXITCODE
        Remove-Item -LiteralPath $TarTempPath -Force -ErrorAction SilentlyContinue
        if ($TarValidationExit -ne 0) {
            Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
            throw 'The tar payload inside the LZMA archive is invalid. Source files were not deleted.'
        }
    }
    else {
        & $TarExe -tf $ArchivePath *> $null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
            throw 'Archive validation failed. Source files were not deleted.'
        }
    }

    foreach ($Entry in $Selected) {
        Remove-Item -LiteralPath $Entry.FullName -Force
    }

    $RemainingFiles = @(Get-ChildItem -LiteralPath $LogPath -File -Recurse -Force)
    [long]$RemainingBytes = 0
    foreach ($File in $RemainingFiles) { $RemainingBytes += [long]$File.Length }
    $RemainingPercent = [math]::Round(($RemainingBytes * 100.0 / $CapacityBytes), 1)

    Write-Output "Archive saved: $ArchivePath"
    Write-Output ("After cleanup: {0:N1} MiB ({1}%)." -f ($RemainingBytes / $MiB), $RemainingPercent)
}
catch {
    [Console]::Error.WriteLine("Error: {0}" -f $_.Exception.Message)
    throw
}
