# ArcForge First Response
# Software Catalog helper module
#
# This file contains Software Catalog parsing and detection helpers.
# Keep this module independent from console output, TXT output, HTML rendering,
# readiness scoring, and runtime orchestration.
#
# These helpers were extracted in v0.28 as ArcForge's first real
# modularization step. Dot-sourcing this file from the main script makes these
# functions available without changing how the Software Readiness checks work.

# Module owner: scripts/ArcForge.SoftwareCatalog.ps1
# MODULE BOUNDARY: these helpers parse the ArcForge Software Catalog and
# translate human-editable catalog rows into concrete detection checks. They are
# used by the Software Readiness section only; avoid coupling them to HTML.
#
# Software Catalog module notes:
# - This module was extracted in v0.28 as the first real modularization step.
# - These helpers should remain independent from console output, TXT output,
#   HTML rendering, readiness scoring, and runtime orchestration.
# - Prefer plain inputs and plain return values so this module stays safe to
#   dot-source from the main script.
# - Test-SoftwareInstalled reads local endpoint state for detection, but it
#   should still only return a Boolean result and avoid report-writing effects.
# - Do not add report-writing side effects to catalog helpers.
# - Do not change detection behavior while maintaining this module.

# Determines whether a catalog software item appears to be installed.
#
# ArcForge supports several detection methods because Windows software can be
# discovered in different ways: command availability, installed services, common
# executable paths, and uninstall-registry display names. This helper combines
# catalog-provided detection data with a few hand-tuned known-app fallbacks.
#
# Input:
# - SoftwareName: Friendly name from the catalog, such as Chrome or VS Code.
# - Commands: CLI commands to test with Get-Command.
# - DisplayNamePatterns: Registry DisplayName wildcard patterns.
# - CommonPaths: File paths to check with Test-Path.
# - Services: Windows service names to check.
# Output:
# - $true when any detection method finds the software.
# - $false when none of the checks find it.
# Boundary expectation:
# - Reads endpoint state, but does not write console/TXT/HTML report output,
#   mutate readiness scoring, or control runtime flow.
# Module owner: scripts/ArcForge.SoftwareCatalog.ps1
function Test-SoftwareInstalled {
    param (
        [string]$SoftwareName = "",
        [string[]]$Commands = @(),
        [string[]]$DisplayNamePatterns = @(),
        [string[]]$CommonPaths = @(),
        [string[]]$Services = @()
    )

    # VS Code is handled explicitly because it is commonly installed per-user,
    # system-wide, or exposed through the "code" command. The generic catalog
    # detection can miss one of those install styles.
    if ($SoftwareName -eq "VS Code") {
        $VsCodePaths = @(
            "$env:ProgramFiles\Microsoft VS Code\Code.exe",
            "${env:ProgramFiles(x86)}\Microsoft VS Code\Code.exe",
            "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
        )

        if (Get-Command "code" -ErrorAction SilentlyContinue) {
            return $true
        }

        foreach ($Path in $VsCodePaths) {
            if (Test-Path $Path) {
                return $true
            }
        }

        $RegistryMatches = Get-ItemProperty `
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*", `
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", `
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Visual Studio Code*" }

        if ($RegistryMatches) {
            return $true
        }
    }

    # Known software detection normalization.
    #
    # This supplements the CSV catalog when Detection Target is too human-readable.
    # Keep this small and focused: it is a fallback layer, not a replacement for
    # maintaining good catalog data.
    $KnownSoftwareDetections = @{
        "Chrome" = @{
            Commands = @("chrome")
            DisplayNamePatterns = @("Google Chrome*")
            CommonPaths = @(
                "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
            )
        }

        "PowerShell" = @{
            Commands = @("pwsh")
            DisplayNamePatterns = @("PowerShell*", "Microsoft PowerShell*")
            CommonPaths = @(
                "$env:ProgramFiles\PowerShell\7\pwsh.exe"
            )
        }

        "Notepad++" = @{
            Commands = @("notepad++")
            DisplayNamePatterns = @("Notepad++*")
            CommonPaths = @(
                "$env:ProgramFiles\Notepad++\notepad++.exe",
                "${env:ProgramFiles(x86)}\Notepad++\notepad++.exe"
            )
        }

        "Windows Terminal" = @{
            Commands = @("wt")
            DisplayNamePatterns = @("Windows Terminal*", "Microsoft Windows Terminal*")
            CommonPaths = @(
                "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
            )
        }

        "7-Zip" = @{
            Commands = @("7z")
            DisplayNamePatterns = @("7-Zip*", "7zip*")
            CommonPaths = @(
                "$env:ProgramFiles\7-Zip\7z.exe",
                "$env:ProgramFiles\7-Zip\7zFM.exe",
                "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
                "${env:ProgramFiles(x86)}\7-Zip\7zFM.exe"
            )
        }

        "OpenHashTab" = @{
            Commands = @()
            DisplayNamePatterns = @("OpenHashTab*")
            CommonPaths = @()
        }

        "FFmpeg (full)" = @{
            Commands = @("ffmpeg")
            DisplayNamePatterns = @("FFmpeg*", "Gyan.FFmpeg*", "Gyan FFmpeg*")
            CommonPaths = @(
                "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe",
                "${env:ProgramFiles(x86)}\ffmpeg\bin\ffmpeg.exe"
            )
        }

        "Python3" = @{
            Commands = @("python", "py")
            DisplayNamePatterns = @("Python*")
            CommonPaths = @(
                "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe",
                "$env:ProgramFiles\Python*\python.exe",
                "${env:ProgramFiles(x86)}\Python*\python.exe"
            )
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SoftwareName)) {
        if ($KnownSoftwareDetections.ContainsKey($SoftwareName)) {
            $KnownDetection = $KnownSoftwareDetections[$SoftwareName]

            $Commands += $KnownDetection.Commands
            $DisplayNamePatterns += $KnownDetection.DisplayNamePatterns
            $CommonPaths += $KnownDetection.CommonPaths
        }
    }

    # Detection pass 1: command lookup.
    # Example: "pwsh", "code", "git", or "ffmpeg" exists in PATH.
    foreach ($Command in $Commands) {
        if (-not [string]::IsNullOrWhiteSpace($Command)) {
            if (Get-Command $Command -ErrorAction SilentlyContinue) {
                return $true
            }
        }
    }

    # Detection pass 2: service lookup.
    # Useful for apps/components that register a Windows service.
    foreach ($Service in $Services) {
        if (-not [string]::IsNullOrWhiteSpace($Service)) {
            if (Get-Service -Name $Service -ErrorAction SilentlyContinue) {
                return $true
            }

            if (Get-CimInstance Win32_Service -Filter "Name='$Service'" -ErrorAction SilentlyContinue) {
                return $true
            }
        }
    }

    # Detection pass 3: common executable paths.
    # Useful when the app exists on disk but is not available as a command.
    foreach ($Path in $CommonPaths) {
        if (-not [string]::IsNullOrWhiteSpace($Path)) {
            if (Test-Path $Path) {
                return $true
            }
        }
    }

    $RegistryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    # Detection pass 4: uninstall registry DisplayName patterns.
    # This catches traditional desktop apps listed in Programs and Features.
    foreach ($RegistryPath in $RegistryPaths) {
        $InstalledApps = Get-ItemProperty $RegistryPath -ErrorAction SilentlyContinue

        foreach ($Pattern in $DisplayNamePatterns) {
            if (-not [string]::IsNullOrWhiteSpace($Pattern)) {
                if ($InstalledApps.DisplayName -like $Pattern) {
                    return $true
                }
            }
        }
    }

    # Generic fallback: match installed programs by software name.
    # This helps catch normal desktop apps when catalog detection targets are too human-readable.
    if (-not [string]::IsNullOrWhiteSpace($SoftwareName)) {
        $SafeSoftwareName = $SoftwareName.Trim()

        $NameFallbackPatterns = @(
            "*$SafeSoftwareName*"
        )

        # Small normalization helpers for common catalog display names.
        switch -Wildcard ($SafeSoftwareName) {
            "Chrome" {
                $NameFallbackPatterns += "*Google Chrome*"
            }
            "PowerShell" {
                $NameFallbackPatterns += "*PowerShell*"
                $NameFallbackPatterns += "*Microsoft PowerShell*"
            }
            "Windows Terminal" {
                $NameFallbackPatterns += "*Windows Terminal*"
            }
            "7-Zip" {
                $NameFallbackPatterns += "*7-Zip*"
                $NameFallbackPatterns += "*7zip*"
            }
            "Notepad++" {
                $NameFallbackPatterns += "*Notepad++*"
            }
            "OpenHashTab" {
                $NameFallbackPatterns += "*OpenHashTab*"
            }
            "Firefox" {
                $NameFallbackPatterns += "*Mozilla Firefox*"
            }
            "Discord" {
                $NameFallbackPatterns += "*Discord*"
            }
        }

        foreach ($RegistryPath in $RegistryPaths) {
            $InstalledApps = Get-ItemProperty $RegistryPath -ErrorAction SilentlyContinue

            foreach ($Pattern in $NameFallbackPatterns) {
                if ($InstalledApps.DisplayName -like $Pattern) {
                    return $true
                }
            }
        }
    }

    return $false
}

# Normalizes a catalog cell into a simple yes/no decision.
#
# The software catalog stores profile membership as text. This helper treats a
# value as selected only when it trims down to "yes", case-insensitively.
#
# Input:
# - Value: Any catalog cell value.
# Output:
# - $true if the value is "yes" after trimming/lowercasing; otherwise $false.
# Module owner: scripts/ArcForge.SoftwareCatalog.ps1
function Test-YesValue {
    param (
        [object]$Value
    )

    return (([string]$Value).Trim().ToLower() -eq "yes")
}

# Safely reads one column from a software catalog CSV row.
#
# This avoids errors when a column is missing or blank. It also trims whitespace
# so downstream comparisons are not thrown off by accidental spaces.
#
# Input:
# - Row: One Import-Csv row object.
# - ColumnName: The column/property name to read.
# Output:
# - Trimmed string value when the column exists.
# - Empty string when the column is missing.
# Module owner: scripts/ArcForge.SoftwareCatalog.ps1
function Get-CatalogValue {
    param (
        [pscustomobject]$Row,
        [string]$ColumnName
    )

    $Property = $Row.PSObject.Properties[$ColumnName]

    if ($Property) {
        return ([string]$Property.Value).Trim()
    }

    return ""
}

# Builds registry DisplayName wildcard patterns for software detection.
#
# Windows uninstall entries often use names that are close to, but not exactly,
# the catalog software name. This helper creates a small set of flexible patterns
# from the friendly software name and the detection target.
#
# Examples:
# - "FFmpeg (full)" also produces a pattern for "FFmpeg".
# - A detection target like "matching Google Chrome" produces "*Google Chrome*".
#
# Input:
# - SoftwareName: Friendly catalog name.
# - DetectionTarget: Raw detection target text from the CSV.
# Output:
# - A unique array of wildcard patterns suitable for DisplayName -like checks.
# Module owner: scripts/ArcForge.SoftwareCatalog.ps1
function Get-DisplayNamePatterns {
    param (
        [string]$SoftwareName,
        [string]$DetectionTarget
    )

    $Patterns = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($SoftwareName)) {
        $Patterns.Add("*$SoftwareName*") | Out-Null

        $BaseName = ($SoftwareName -replace "\s*\(.*?\)", "").Trim()
        if ($BaseName -and $BaseName -ne $SoftwareName) {
            $Patterns.Add("*$BaseName*") | Out-Null
        }
    }

    if ($DetectionTarget -match "matching\s+(.+)$") {
        $TargetName = $Matches[1].Trim()
        if ($TargetName) {
            $Patterns.Add("*$TargetName*") | Out-Null

            $TargetBaseName = ($TargetName -replace "\s*\(.*?\)", "").Trim()
            if ($TargetBaseName -and $TargetBaseName -ne $TargetName) {
                $Patterns.Add("*$TargetBaseName*") | Out-Null
            }
        }
    }

    return @($Patterns | Sort-Object -Unique)
}

# Splits a catalog detection target into individual candidates.
#
# Catalog cells may contain multiple possible detections separated by slashes,
# commas, semicolons, or the word "or". This helper turns that single string into
# a clean list the detection parser can inspect one item at a time.
#
# Input:
# - DetectionTarget: Raw detection target text from the CSV.
# Output:
# - Array of trimmed candidate strings.
# Module owner: scripts/ArcForge.SoftwareCatalog.ps1
function Split-DetectionCandidates {
    param (
        [string]$DetectionTarget
    )

    if ([string]::IsNullOrWhiteSpace($DetectionTarget)) {
        return @()
    }

    return @(
        $DetectionTarget -split "\s*/\s*|;|,|\s+or\s+" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

# Converts one software catalog row into concrete detection instructions.
#
# The CSV is human-readable, while Test-SoftwareInstalled needs structured lists
# of commands, services, paths, and registry patterns. This helper bridges that
# gap by parsing the row and returning a standardized detection config object.
#
# Helper relationship:
# - Uses Get-CatalogValue, Split-DetectionCandidates, and Get-DisplayNamePatterns
#   to turn one CSV row into plain arrays for Test-SoftwareInstalled.
#
# Input:
# - CatalogRow: One Import-Csv software catalog row.
# Output:
# - PSCustomObject with these arrays:
#   - Commands
#   - DisplayNamePatterns
#   - CommonPaths
#   - Services
# Boundary expectation:
# - Returns data only; it should not perform installation checks or write report
#   output.
# Module owner: scripts/ArcForge.SoftwareCatalog.ps1
function Get-SoftwareDetectionConfig {
    param (
        [pscustomobject]$CatalogRow
    )

    $SoftwareName = Get-CatalogValue -Row $CatalogRow -ColumnName "Software Name"
    $DetectionMethod = Get-CatalogValue -Row $CatalogRow -ColumnName "Detection Method"
    $DetectionTarget = Get-CatalogValue -Row $CatalogRow -ColumnName "Detection Target"

    $Commands = New-Object System.Collections.Generic.List[string]
    $CommonPaths = New-Object System.Collections.Generic.List[string]
    $Services = New-Object System.Collections.Generic.List[string]

    $Candidates = Split-DetectionCandidates -DetectionTarget $DetectionTarget

    foreach ($Candidate in $Candidates) {
        $CleanCandidate = $Candidate.Trim()

        if ([string]::IsNullOrWhiteSpace($CleanCandidate)) {
            continue
        }

        if ($DetectionMethod -match "Command") {
            if ($CleanCandidate -match "^[A-Za-z0-9_.+\-\*]+(\.exe)?$") {
                $Commands.Add(($CleanCandidate -replace "\.exe$", "")) | Out-Null
            }
        }

        if ($CleanCandidate -match "\.exe$") {
            $ExeName = Split-Path $CleanCandidate -Leaf
            $CommandName = $ExeName -replace "\.exe$", ""

            if ($CommandName) {
                $Commands.Add($CommandName) | Out-Null
            }

            $CommonPaths.Add((Join-Path $env:ProgramFiles "*\$ExeName")) | Out-Null

            if (${env:ProgramFiles(x86)}) {
                $CommonPaths.Add((Join-Path ${env:ProgramFiles(x86)} "*\$ExeName")) | Out-Null
            }

            if ($env:LOCALAPPDATA) {
                $CommonPaths.Add((Join-Path $env:LOCALAPPDATA "Programs\*\$ExeName")) | Out-Null
            }
        }

        if ($DetectionMethod -match "Service") {
            if ($CleanCandidate -match "(?i)^(.+?)\s+service$") {
                $Services.Add($Matches[1].Trim()) | Out-Null
            }
            elseif ($CleanCandidate -match "^[A-Za-z0-9_.\-]+$") {
                $Services.Add($CleanCandidate) | Out-Null
            }
        }
    }

    $DisplayNamePatterns = Get-DisplayNamePatterns -SoftwareName $SoftwareName -DetectionTarget $DetectionTarget

    [pscustomobject]@{
        Commands = @($Commands | Sort-Object -Unique)
        DisplayNamePatterns = @($DisplayNamePatterns | Sort-Object -Unique)
        CommonPaths = @($CommonPaths | Sort-Object -Unique)
        Services = @($Services | Sort-Object -Unique)
    }
}
