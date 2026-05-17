# ArcForge First Response
# ArcForge First Response Report v0.24

param (
    [ValidateSet("General", "Gaming", "Creator", "Developer", "Homelab", "Secure")]
    [string]$BattlestationProfile = "General"
)

$ReportDate = Get-Date
$ComputerName = $env:COMPUTERNAME
$CurrentUser = $env:USERNAME

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ReportFolder = Join-Path $ProjectRoot "reports"
$Timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
$ProfileNameForFile = $BattlestationProfile.ToLower()
$ReportFile = Join-Path $ReportFolder "$ComputerName-$ProfileNameForFile-first-response-$Timestamp.txt"
$HtmlReportFile = Join-Path $ReportFolder "$ComputerName-$ProfileNameForFile-first-response-$Timestamp.html"
$ReportId = "AFR-$ComputerName-$ProfileNameForFile-$Timestamp"

$CheckCounts = @{
    OK = 0
    WARN = 0
    FAIL = 0
}

$script:ReportLines = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path $ReportFolder)) {
    New-Item -Path $ReportFolder -ItemType Directory | Out-Null
}

# Adds a line to the in-memory TXT report buffer.
#
# ArcForge writes results to the console immediately, but it also needs to save
# the same information to a TXT report at the end of the run. This helper keeps
# report-writing consistent by appending text to $script:ReportLines.
#
# Input:
# - Line: The exact text to add. Defaults to a blank line when omitted.
# Output:
# - No direct output. Updates the script-scoped ReportLines list.
function Add-ReportLine {
    param (
        [string]$Line = ""
    )

    $script:ReportLines.Add($Line) | Out-Null
}

# Prints one check result to the console and records it in the TXT report.
#
# This is the main output helper used throughout the script. It standardizes the
# [OK] / [WARN] / [FAIL] format, applies console colors, aligns labels, and
# increments the summary counters unless CountResult is disabled.
#
# Input:
# - Status: OK, WARN, FAIL, or another status string.
# - Label: The left-side label shown beside the status.
# - Value: The result details shown after the label.
# - CountResult: Whether this line should affect the final summary totals.
# Output:
# - Writes to the console.
# - Adds the same formatted line to $script:ReportLines.
# - Updates $script:CheckCounts when CountResult is true.
function Write-Result {
    param (
        [string]$Status,
        [string]$Label,
        [string]$Value,
        [bool]$CountResult = $true
    )

    $StatusUpper = $Status.ToUpper()
    $StatusFieldWidth = 6
    $CurrentStatusWidth = $StatusUpper.Length + 2
    $StatusPadding = " " * ($StatusFieldWidth - $CurrentStatusWidth)
    $LabelPadded = "{0,-18}" -f $Label

    if ($CountResult -and $script:CheckCounts.ContainsKey($StatusUpper)) {
        $script:CheckCounts[$StatusUpper]++
    }

    Write-Host "[" -NoNewline -ForegroundColor Gray

    switch ($StatusUpper) {
        "OK"   { Write-Host "OK" -NoNewline -ForegroundColor Green }
        "WARN" { Write-Host "WARN" -NoNewline -ForegroundColor Yellow }
        "FAIL" { Write-Host "FAIL" -NoNewline -ForegroundColor Red }
        default { Write-Host $StatusUpper -NoNewline -ForegroundColor Gray }
    }

    Write-Host "]$StatusPadding  " -NoNewline -ForegroundColor Gray
    Write-Host "$LabelPadded $Value" -ForegroundColor Gray

    Add-ReportLine -Line ("[{0}]{1}  {2} {3}" -f $StatusUpper, $StatusPadding, $LabelPadded, $Value)
}

# Starts a new report section in both the console and TXT report.
#
# Sections are simple bracketed headings like [SYSTEM], [NETWORK], or [SUMMARY].
# The HTML report later uses these headings to group raw findings into cards.
#
# Input:
# - Title: The section name to display.
# Output:
# - Writes a blank line and section heading to the console.
# - Adds the same section marker to $script:ReportLines.
function Write-Section {
    param (
        [string]$Title
    )

    Write-Host ""
    Write-Host "[$Title]" -ForegroundColor Gray

    Add-ReportLine
    Add-ReportLine -Line "[$Title]"
}

# Builds the final summary section from the accumulated check counters.
#
# This function does not run new health checks. It reads the OK/WARN/FAIL totals
# collected by Write-Result during the script run, then prints an overall status.
#
# Output:
# - Adds the [SUMMARY] section.
# - Writes total checks, passed checks, warnings, failures, and overall status.
# - Uses CountResult:$false so summary lines do not inflate their own totals.
function Write-Summary {
    Write-Section -Title "SUMMARY"

    $PassedChecks = $script:CheckCounts.OK
    $Warnings = $script:CheckCounts.WARN
    $Failures = $script:CheckCounts.FAIL
    $TotalChecks = $PassedChecks + $Warnings + $Failures

    Write-Result -Status "OK" -Label "Total Checks:" -Value $TotalChecks -CountResult:$false
    Write-Result -Status "OK" -Label "Passed Checks:" -Value $PassedChecks -CountResult:$false

    if ($Warnings -gt 0) {
        Write-Result -Status "WARN" -Label "Warnings:" -Value $Warnings -CountResult:$false
    }
    else {
        Write-Result -Status "OK" -Label "Warnings:" -Value $Warnings -CountResult:$false
    }

    if ($Failures -gt 0) {
        Write-Result -Status "FAIL" -Label "Failures:" -Value $Failures -CountResult:$false
    }
    else {
        Write-Result -Status "OK" -Label "Failures:" -Value $Failures -CountResult:$false
    }

    if ($Failures -gt 0) {
        Write-Result -Status "FAIL" -Label "Overall Status:" -Value "Action required" -CountResult:$false
    }
    elseif ($Warnings -gt 0) {
        Write-Result -Status "WARN" -Label "Overall Status:" -Value "Attention recommended" -CountResult:$false
    }
    else {
        Write-Result -Status "OK" -Label "Overall Status:" -Value "Healthy" -CountResult:$false
    }
}

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
# Output:
# - A unique array of wildcard patterns suitable for DisplayName -like checks.
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
# Input:
# - CatalogRow: One Import-Csv software catalog row.
# Output:
# - PSCustomObject with these arrays:
#   - Commands
#   - DisplayNamePatterns
#   - CommonPaths
#   - Services
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


# Groups raw TXT report lines into known report sections.
#
# The HTML report does not run checks again. Instead, it reads the lines already
# captured in $ReportLines and sorts them under major section names. Only known
# sections are captured so accidental bracketed lines do not create random cards.
#
# Input:
# - ReportLines: The full collected report output.
# Output:
# - Hashtable where each known section name maps to a list of lines.
function Get-ArcForgeReportSections {
    param (
        [string[]]$ReportLines
    )

    $KnownSections = @(
        "SYSTEM",
        "UPTIME",
        "PROCESSES",
        "SERVICES",
        "STORAGE",
        "NETWORK",
        "SOFTWARE",
        "SECURITY",
        "UPDATES",
        "SUMMARY"
    )

    $Sections = @{}

    foreach ($Section in $KnownSections) {
        $Sections[$Section] = [System.Collections.Generic.List[string]]::new()
    }

    $CurrentSection = $null

    foreach ($Line in $ReportLines) {
        if ($Line -match '^\[(?<Section>[^\]]+)\]\s*$') {
            $CandidateSection = $Matches.Section.Trim().ToUpperInvariant()

            if ($KnownSections -contains $CandidateSection) {
                $CurrentSection = $CandidateSection
                continue
            }
        }

        if ($CurrentSection -and -not [string]::IsNullOrWhiteSpace($Line)) {
            $Sections[$CurrentSection].Add($Line) | Out-Null
        }
    }

    return $Sections
}

# Generates the self-contained static HTML report.
#
# This function turns the raw report lines and summary counters into a polished
# local HTML file. It does not use JavaScript, external CSS, or external assets.
# The HTML acts as a future GUI prototype while keeping ArcForge simple and local.
#
# Input:
# - OutputPath: Destination .html file path.
# - ReportId, ComputerName, CurrentUser, BattlestationProfile, GeneratedAt:
#   Metadata displayed in the report header/cards.
# - CheckCounts: Final OK/WARN/FAIL totals.
# - ReportLines: Raw TXT report lines used to build sections and findings.
# Output:
# - Writes a complete HTML document to OutputPath.
function New-ArcForgeHtmlReport {
    param (
        [string]$OutputPath,
        [string]$ReportId,
        [string]$ComputerName,
        [string]$CurrentUser,
        [string]$BattlestationProfile,
        [datetime]$GeneratedAt,
        [hashtable]$CheckCounts,
        [string[]]$ReportLines
    )

    # Encodes text before placing it into HTML.
    #
    # This prevents report values containing characters like <, >, or & from
    # breaking the HTML structure or being interpreted as markup.
    function ConvertTo-HtmlSafeText {
        param (
            [string]$Text
        )

        return [System.Net.WebUtility]::HtmlEncode($Text)
    }

    # Converts raw finding lines into an HTML <li> list.
    #
    # Some section line collections can be nested arrays, especially when multiple
    # report sections are combined into one HTML card. This helper flattens them,
    # removes blanks, HTML-encodes every line, and wraps each finding in <code>.
    #
    # Output:
    # - A string containing one or more <li> elements.
    # - A muted placeholder <li> when the section has no findings.
    function ConvertTo-ArcForgeHtmlFindingList {
        param (
            [object[]]$Lines,
            [string]$EmptyMessage = "No findings captured for this section. See Raw Findings for the complete report output."
        )

        $FlattenedLines = @(
            foreach ($Line in $Lines) {
                if ($null -eq $Line) {
                    continue
                }

                if ($Line -is [System.Collections.IEnumerable] -and $Line -isnot [string]) {
                    foreach ($Item in $Line) {
                        if ($null -ne $Item) {
                            [string]$Item
                        }
                    }
                }
                else {
                    [string]$Line
                }
            }
        )

        $CleanLines = @(
            $FlattenedLines |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { ConvertTo-HtmlSafeText $_ }
        )

        if (-not $CleanLines -or $CleanLines.Count -eq 0) {
            return "<li class=`"muted`">$(ConvertTo-HtmlSafeText $EmptyMessage)</li>"
        }

        return ($CleanLines | ForEach-Object {
            "<li><code>$_</code></li>"
        }) -join "`n"
    }

    # Flattens nested line arrays into a simple string array.
    #
    # Used by readiness scoring so combined sections like System can be counted
    # the same way as single sections like Network or Security.
    function Get-ArcForgeFlattenedLines {
        param (
            [object[]]$Lines
        )

        return @(
            foreach ($Line in $Lines) {
                if ($null -eq $Line) {
                    continue
                }

                if ($Line -is [System.Collections.IEnumerable] -and $Line -isnot [string]) {
                    foreach ($Item in $Line) {
                        if ($null -ne $Item) {
                            [string]$Item
                        }
                    }
                }
                else {
                    [string]$Line
                }
            }
        )
    }

    # Scores one report area for the Readiness Overview cards.
    #
    # This function counts how many [OK], [WARN], and [FAIL] lines exist in a
    # section, then assigns the card status shown in the HTML dashboard.
    #
    # Output:
    # - PSCustomObject containing name, status label, CSS class, counts, and summary.
    function Get-ArcForgeSectionReadiness {
        param (
            [string]$Name,
            [object[]]$Lines
        )

        $FlattenedLines = Get-ArcForgeFlattenedLines -Lines $Lines

        $OkCount = @($FlattenedLines | Where-Object { $_ -match '^\[OK\]' }).Count
        $WarnCount = @($FlattenedLines | Where-Object { $_ -match '^\[WARN\]' }).Count
        $FailCount = @($FlattenedLines | Where-Object { $_ -match '^\[FAIL\]' }).Count

        if ($FailCount -gt 0) {
            $Status = "Critical"
            $StatusClass = "readiness-critical"
            $Summary = "Critical findings require attention."
        }
        elseif ($WarnCount -gt 0) {
            $Status = "Attention"
            $StatusClass = "readiness-attention"
            $Summary = "Warnings found. Review recommended actions."
        }
        elseif ($OkCount -gt 0) {
            $Status = "OK"
            $StatusClass = "readiness-ok"
            $Summary = "All checks passed."
        }
        else {
            $Status = "No Data"
            $StatusClass = "readiness-neutral"
            $Summary = "No findings detected in this section."
        }

        [pscustomobject]@{
            Name        = $Name
            Status      = $Status
            StatusClass = $StatusClass
            OkCount     = $OkCount
            WarnCount   = $WarnCount
            FailCount   = $FailCount
            Summary     = $Summary
        }
    }

    # Builds the HTML block for the Readiness Overview dashboard cards.
    #
    # The card data is prepared by Get-ArcForgeSectionReadiness. This helper only
    # converts those objects into HTML markup for the final report.
    function New-ArcForgeReadinessOverviewHtml {
        param (
            [object[]]$ReadinessCards
        )

        $CardBlocks = @()

        foreach ($Card in $ReadinessCards) {
            $SafeName = ConvertTo-HtmlSafeText $Card.Name
            $SafeStatus = ConvertTo-HtmlSafeText $Card.Status
            $SafeSummary = ConvertTo-HtmlSafeText $Card.Summary

            # v0.22 presentation-only status classes.
            # These classes control the left-border accent for the Readiness
            # Overview cards. They do not change the underlying status values
            # or the shared StatusClass property used elsewhere in the HTML.
            $CardVisualClass = switch ($Card.Status) {
                "OK"        { "readiness-card-ok" }
                "Attention" { "readiness-card-warn" }
                "Critical"  { "readiness-card-fail" }
                default     { "readiness-card-unknown" }
            }

            # v0.22 presentation-only navigation target.
            # The Readiness Overview cards now behave like dashboard shortcuts.
            # Each card jumps to the matching detailed report section by using
            # the same static anchor IDs already used by the sidebar navigation.
            #
            # Important:
            # - This is only an HTML link target.
            # - No JavaScript is used.
            # - This does not change check logic, console output, or TXT output.
            # - If a card does not jump correctly, compare these anchor values
            #   with the matching id="section-name" values in the HTML sections.
            $CardAnchor = switch ($Card.Name) {
                "System"             { "system" }
                "Network"            { "network" }
                "Software Readiness" { "software-readiness" }
                "Security"           { "security" }
                "Updates"            { "updates" }
                default              { "readiness-overview" }
            }

            $SafeCardAnchor = ConvertTo-HtmlSafeText $CardAnchor

            $CardBlocks += @"
            <a class="readiness-card-link" href="#$SafeCardAnchor" title="Jump to $SafeName details" aria-label="Jump to $SafeName details">
                <article class="readiness-card $($Card.StatusClass) $CardVisualClass">
                    <div class="readiness-card-header">
                        <h3>$SafeName</h3>
                        <span class="readiness-status">$SafeStatus</span>
                    </div>
                    <div class="readiness-counts" aria-label="$SafeName readiness counts">
                        <span class="readiness-count-item readiness-count-ok"><strong>$($Card.OkCount)</strong><span>OK</span></span>
                        <span class="readiness-count-item readiness-count-warn"><strong>$($Card.WarnCount)</strong><span>WARN</span></span>
                        <span class="readiness-count-item readiness-count-fail"><strong>$($Card.FailCount)</strong><span>FAIL</span></span>
                    </div>
                    <p class="readiness-card-summary">$SafeSummary</p>
                </article>
            </a>
"@
        }

        $CardsHtml = $CardBlocks -join "`n"

        return @"
        <section id="readiness-overview" class="card section">
            <div class="section-title">
                <h2>Readiness Overview</h2>
                <p>Dashboard-style summary of major battlestation readiness areas.</p>
            </div>
            <div class="readiness-grid">
$CardsHtml
            </div>
        </section>
"@
    }

    # Builds the compact v0.20 Endpoint Summary badge shown at the top of the
    # HTML report.
    #
    # Why this exists:
    # - The first screen of the HTML report should feel like a quick endpoint
    #   identity card, similar to what a tech might scan in an RMM tool.
    # - A tech should be able to immediately identify the computer, current user,
    #   selected Battlestation Profile, generated time, overall status, and check
    #   totals without reading a large grid of separate cards.
    #
    # Input:
    # - Report metadata that was already being displayed in the Report Summary.
    # - Existing OK/WARN/FAIL/Total counters and the existing OverallStatus value.
    #
    # Output:
    # - A presentation-only HTML block inserted into the Report Summary section.
    #
    # Important:
    # - This does not run checks.
    # - This does not change scoring.
    # - This does not change console output.
    # - This does not change TXT report output.
    #
    # Troubleshooting rule:
    # - If the top badge looks wrong, inspect the endpoint-summary CSS classes and
    #   the values passed into this helper before changing health-check logic.
    function New-ArcForgeEndpointSummaryHtml {
        param (
            [string]$ReportId,
            [string]$ComputerName,
            [string]$CurrentUser,
            [string]$BattlestationProfile,
            [datetime]$GeneratedAt,
            [string]$OverallStatus,
            [string]$StatusClass,
            [int]$OkCount,
            [int]$WarnCount,
            [int]$FailCount,
            [int]$TotalChecks
        )

        $SafeReportId = ConvertTo-HtmlSafeText $ReportId
        $SafeComputerName = ConvertTo-HtmlSafeText $ComputerName
        $SafeCurrentUser = ConvertTo-HtmlSafeText $CurrentUser
        $SafeBattlestationProfile = ConvertTo-HtmlSafeText $BattlestationProfile
        $SafeGeneratedAt = ConvertTo-HtmlSafeText $GeneratedAt
        $SafeOverallStatus = ConvertTo-HtmlSafeText $OverallStatus

        return @"
        <section class="endpoint-summary card" aria-label="Endpoint Summary">
            <div class="endpoint-main">
                <div class="endpoint-identity">
                    <div class="endpoint-kicker">Endpoint Summary</div>
                    <div class="endpoint-title-row">
                        <h2>$SafeComputerName</h2>
                        <span class="endpoint-status-pill $StatusClass">$SafeOverallStatus</span>
                    </div>
                    <p class="endpoint-description">Static local triage snapshot for this workstation.</p>

                    <div class="endpoint-meta-stack">
                        <div class="endpoint-meta-item">
                            <span class="endpoint-meta-label">Current User</span>
                            <strong>$SafeCurrentUser</strong>
                        </div>
                        <div class="endpoint-meta-item">
                            <span class="endpoint-meta-label">Battlestation Profile</span>
                            <strong>$SafeBattlestationProfile</strong>
                        </div>
                    </div>
                </div>

                <div class="endpoint-status-panel">
                    <div class="endpoint-status-heading">Check Totals</div>
                    <div class="endpoint-count-strip" aria-label="ArcForge check result totals">
                        <div class="endpoint-count endpoint-count-ok">
                            <span class="endpoint-count-number">$OkCount</span>
                            <span class="endpoint-count-label">OK</span>
                        </div>
                        <div class="endpoint-count endpoint-count-warn">
                            <span class="endpoint-count-number">$WarnCount</span>
                            <span class="endpoint-count-label">WARN</span>
                        </div>
                        <div class="endpoint-count endpoint-count-fail">
                            <span class="endpoint-count-number">$FailCount</span>
                            <span class="endpoint-count-label">FAIL</span>
                        </div>
                        <div class="endpoint-count endpoint-count-total">
                            <span class="endpoint-count-number">$TotalChecks</span>
                            <span class="endpoint-count-label">TOTAL</span>
                        </div>
                    </div>
                </div>
            </div>

            <div class="endpoint-bottom-row">
                <div class="endpoint-meta-item">
                    <span class="endpoint-meta-label">Report ID</span>
                    <strong>$SafeReportId</strong>
                </div>
                <div class="endpoint-meta-item">
                    <span class="endpoint-meta-label">Generated At</span>
                    <strong>$SafeGeneratedAt</strong>
                </div>
            </div>
        </section>
"@
    }


    # Assigns one WARN/FAIL finding to the triage bucket shown in Recommended Actions.
    #
    # Why this exists:
    # - The raw report lines are useful, but a long flat list is hard to scan.
    # - This helper lets the HTML report group problems into practical buckets,
    #   almost like a small ticket queue.
    # - It only affects the HTML Recommended Actions section. It does not change
    #   the checks themselves, the console output, or the TXT report.
    #
    # How it works:
    # - PowerShell's -match operator checks whether the finding contains certain
    #   words or phrases.
    # - The first matching bucket wins because each match immediately returns.
    # - Anything that does not match a known pattern falls back to General Findings.
    #
    # Input:
    # - Finding: One raw report line such as:
    #   [WARN]    DNS: Resolution failed
    #
    # Output:
    # - A category name used as a heading in the Recommended Actions panel.
    function Get-ArcForgeActionCategory {
        param (
            [string]$Finding
        )

        # Missing profile software and catalog problems belong together because
        # they affect whether the selected Battlestation Profile is fully ready.
        if ($Finding -match 'recommended for .+ profile but not found|Profile Tools|Catalog File|Catalog Error') {
            return "Profile Readiness"
        }

        # Network-related findings are grouped together so internet, gateway, DNS,
        # and adapter issues are easy to review in one place.
        if ($Finding -match 'Gateway|Internet Ping|DNS|IP Address|Network Adapter') {
            return "Network Connectivity"
        }

        # Security posture findings are grouped separately because they usually
        # need a manual review rather than an immediate technical repair.
        if ($Finding -match 'Local Admins|Firewall|Antivirus|Defender') {
            return "Security Review"
        }

        # Pending reboot could also be considered system stability, but for this
        # report it is more useful under Update Readiness because reboots often
        # block patching, software installs, and troubleshooting.
        if ($Finding -match 'Pending Reboot|Windows Update|Update Service|BITS Service|Last Hotfix|Hotfix') {
            return "Update Readiness"
        }

        # System-level findings are things that affect the local workstation's
        # stability or day-to-day readiness.
        if ($Finding -match 'Uptime|Hung Apps|Processes|Services|Storage|Disk') {
            return "System Stability"
        }

        # Safe fallback. This prevents a finding from disappearing just because
        # it did not match one of the known patterns above.
        return "General Findings"
    }

    # Gives each action item a short, beginner-friendly next step.
    #
    # Why this exists:
    # - A finding tells the user what ArcForge noticed.
    # - A suggested action tells the user what to do next.
    # - Keeping this in one helper makes the wording easier to improve later.
    #
    # Important:
    # - These are intentionally simple Tier-1 style suggestions.
    # - The detailed technical evidence still lives in the normal section cards
    #   and in Raw Findings.
    # - This helper does not fix anything automatically.
    #
    # Input:
    # - Finding: One raw WARN/FAIL report line.
    # - BattlestationProfile: The selected profile, such as Developer or Gaming.
    #
    # Output:
    # - A plain English remediation suggestion displayed under the action item.
    function Get-ArcForgeSuggestedAction {
        param (
            [string]$Finding,
            [string]$BattlestationProfile
        )

        # Long uptime can make troubleshooting noisy because a reboot may clear
        # pending updates, stale services, driver weirdness, or old hung processes.
        if ($Finding -match 'Uptime') {
            return "Reboot during the next maintenance window, then rerun ArcForge."
        }

        # Hung apps are usually best handled by closing/restarting the affected
        # apps before assuming the whole workstation is unhealthy.
        if ($Finding -match 'Hung Apps') {
            return "Close or restart the affected apps, then rerun ArcForge."
        }

        # A network warning could come from several checks, so this suggestion
        # points the user toward the most likely basic troubleshooting areas.
        if ($Finding -match 'Gateway|Internet Ping|DNS|IP Address|Network Adapter') {
            return "Verify network connectivity, adapter configuration, DNS settings, and gateway reachability."
        }

        # Local administrator membership is not automatically bad, but it should
        # be intentional. This keeps the action worded as a review item.
        if ($Finding -match 'Local Admins') {
            return "Confirm all local administrator accounts are expected."
        }

        # Firewall checks can be satisfied by Windows Firewall or a valid third-
        # party firewall, so the suggestion avoids assuming Defender is the only answer.
        if ($Finding -match 'Firewall') {
            return "Verify Windows Firewall or the active third-party firewall is enabled."
        }

        # Antivirus can also be provided by third-party tools, so this suggestion
        # asks the user to confirm the expected provider is healthy.
        if ($Finding -match 'Antivirus|Defender') {
            return "Confirm an expected antivirus provider is installed, enabled, and reporting healthy."
        }

        # Pending reboot is often the first thing to resolve before troubleshooting
        # Windows Update, installers, or other system changes.
        if ($Finding -match 'Pending Reboot') {
            return "Reboot before continuing patching, installs, or troubleshooting."
        }

        # Windows Update-related warnings are grouped around patch readiness.
        if ($Finding -match 'Windows Update|Update Service|BITS Service|Last Hotfix|Hotfix') {
            return "Review Windows Update readiness before patching or installing additional software."
        }

        # Catalog-level issues are different from missing apps. They may mean the
        # runtime CSV is missing, broken, or not matching the selected profile.
        if ($Finding -match 'Profile Tools|Catalog File|Catalog Error') {
            return "Review the ArcForge Software Catalog and confirm the selected Battlestation Profile is using the expected runtime catalog."
        }

        # Safe fallback for any current or future WARN/FAIL line that does not
        # match the more specific patterns above.
        return "Review the related section for details, then rerun ArcForge after remediation."
    }

    # Converts raw WARN/FAIL report lines into grouped action objects.
    #
    # Why this exists:
    # - The checks currently write human-readable report lines, not structured
    #   objects. That is fine for now.
    # - This function acts as a thin presentation adapter. It reads those existing
    #   lines and prepares clean objects for the HTML action panel.
    # - This avoids refactoring the check engine during v0.17.
    #
    # What gets filtered out:
    # - The SUMMARY section includes lines like "Warnings:" and "Failures:".
    #   Those are totals, not actionable findings, so they are excluded.
    # - "Overall Status" is also excluded because it is a summary label, not a
    #   specific repair item.
    #
    # Special software handling:
    # - A profile like Developer can have many missing recommended tools.
    # - Listing every missing tool inside Recommended Actions makes the action
    #   queue noisy.
    # - This function collects those missing-tool warnings and replaces them with
    #   one summarized Profile Readiness action.
    # - The full missing-tools list is still preserved in Software Readiness and
    #   Raw Findings.
    #
    # Input:
    # - ReportLines: The complete in-memory TXT report lines.
    # - BattlestationProfile: The selected profile name.
    #
    # Output:
    # - PSCustomObject items with Category, Severity, Title, Detail, and SuggestedAction.
    function Get-ArcForgeActionItems {
        param (
            [string[]]$ReportLines,
            [string]$BattlestationProfile
        )

        # Start with every WARN/FAIL line from the finished report.
        # Then remove summary counters so the action queue only shows real issues.
        $FindingLines = @(
            $ReportLines |
                Where-Object {
                    $_ -match '^\[(WARN|FAIL)\]' -and
                    $_ -notmatch '^\[(WARN|FAIL)\]\s+Warnings:' -and
                    $_ -notmatch '^\[(WARN|FAIL)\]\s+Failures:' -and
                    $_ -notmatch '^\[(WARN|FAIL)\]\s+Overall Status:'
                }
        )

        # ActionItems will hold the final objects that become cards in HTML.
        $ActionItems = [System.Collections.Generic.List[object]]::new()

        # MissingProfileTools temporarily stores software warnings that should be
        # summarized into one action instead of displayed one-by-one.
        $MissingProfileTools = [System.Collections.Generic.List[string]]::new()

        foreach ($Finding in $FindingLines) {
            # Detect missing recommended profile tools.
            #
            # Example matched line:
            # [WARN]    Git: Recommended for Developer profile but not found
            #
            # Named regex groups like (?<Severity>WARN|FAIL) make the pattern
            # easier to understand later, even though this specific branch only
            # needs to count the matching lines.
            if ($Finding -match '^\[(?<Severity>WARN|FAIL)\]\s+(?<ToolName>.+?):\s+Recommended for (?<Profile>.+?) profile but not found$') {
                $MissingProfileTools.Add($Finding) | Out-Null
                continue
            }

            # Default to WARN so a malformed line still has a safe visual style.
            # If the line begins with [WARN] or [FAIL], use that real severity.
            $Severity = "WARN"
            if ($Finding -match '^\[(?<Severity>WARN|FAIL)\]') {
                $Severity = $Matches.Severity
            }

            # Remove the leading [WARN] or [FAIL] tag from the title because the
            # visual badge already shows severity in the HTML action card.
            $Title = $Finding -replace '^\[(WARN|FAIL)\]\s+', ''

            # Build one normalized action object for the HTML renderer.
            # The renderer does not need to know how the item was detected; it
            # only needs these simple fields.
            $ActionItems.Add([pscustomobject]@{
                Category        = Get-ArcForgeActionCategory -Finding $Finding
                Severity        = $Severity
                Title           = $Title
                Detail          = ""
                SuggestedAction = Get-ArcForgeSuggestedAction -Finding $Finding -BattlestationProfile $BattlestationProfile
            }) | Out-Null
        }

        # Add one summarized software readiness action after all findings have
        # been scanned. This keeps Recommended Actions readable while preserving
        # the complete details elsewhere in the report.
        if ($MissingProfileTools.Count -gt 0) {
            $ActionItems.Add([pscustomobject]@{
                Category        = "Profile Readiness"
                Severity        = "WARN"
                Title           = "$($MissingProfileTools.Count) recommended $BattlestationProfile profile tools are missing."
                Detail          = "Software Readiness contains the full missing-tools list."
                SuggestedAction = "Review Software Readiness before using this workstation for $BattlestationProfile work."
            }) | Out-Null
        }

        # Return as an array so the caller can safely count/filter the result,
        # even when there is only one action item.
        return @($ActionItems)
    }

    # Builds the severity-first Recommended Actions triage panel.
    #
    # Why this exists:
    # - Get-ArcForgeActionItems prepares clean action objects.
    # - This function turns those objects into static HTML.
    # - Separating data preparation from HTML generation makes future polishing
    #   easier without changing the report parsing logic.
    #
    # v0.23 triage rule:
    # - Recommended Actions should behave like a local triage queue.
    # - FAIL items are shown first across the entire queue, regardless of category.
    # - WARN items are shown after FAIL items.
    # - The original category is still shown inside each card so the technician
    #   knows which evidence section to review next.
    #
    # Important:
    # - The output is static HTML only.
    # - No JavaScript is used.
    # - No external dependencies are used.
    # - This only changes the HTML Recommended Actions section.
    # - This does not change readiness scoring, check logic, console output, or TXT output.
    #
    # Input:
    # - ActionItems: Objects returned by Get-ArcForgeActionItems.
    #
    # Output:
    # - A string containing the complete Recommended Actions <section> block.
    function New-ArcForgeRecommendedActionsHtml {
        param (
            [object[]]$ActionItems
        )

        # If there are no WARN/FAIL action items, show a clean healthy-state card
        # instead of leaving the section blank.
        if (-not $ActionItems -or $ActionItems.Count -eq 0) {
            return @"
        <section id="recommended-actions" class="card section">
            <div class="section-title">
                <h2>Recommended Actions</h2>
                <p>No immediate recommended actions. System appears healthy based on current checks.</p>
            </div>
        </section>
"@
        }

        # Build summary counts for the small triage strip at the top of the section.
        # These counts are presentation-only. They summarize the action objects that
        # already exist; they do not change any health-check result or score.
        $TotalActionCount = @($ActionItems).Count
        $FailActionCount = @($ActionItems | Where-Object { $_.Severity -eq "FAIL" }).Count
        $WarnActionCount = @($ActionItems | Where-Object { $_.Severity -eq "WARN" }).Count

        # Describes the severity-first queue sections in the order they should be
        # displayed. This is what makes FAIL appear before WARN globally instead of
        # hiding a FAIL item underneath earlier category groups.
        $PriorityGroups = @(
            [pscustomobject]@{
                Severity = "FAIL"
                Heading  = "Failed Actions"
                Summary  = "Issues that indicate an expected check failed and should be reviewed first."
            },
            [pscustomobject]@{
                Severity = "WARN"
                Heading  = "Warnings"
                Summary  = "Items that need attention, confirmation, or follow-up review."
            }
        )

        $GroupBlocks = @()

        foreach ($PriorityGroup in $PriorityGroups) {
            # Pull only the action items matching the current severity.
            # Wrapping the result in @() makes .Count reliable even if there is
            # only one matching item.
            $SeverityItems = @($ActionItems | Where-Object { $_.Severity -eq $PriorityGroup.Severity })

            # Skip empty severity groups so the report only shows useful queues.
            if (-not $SeverityItems -or $SeverityItems.Count -eq 0) {
                continue
            }

            $ItemBlocks = @()

            foreach ($Item in $SeverityItems) {
                # Build a CSS class from the severity, such as action-warn or
                # action-fail. ToLowerInvariant avoids locale-specific casing.
                $SeverityClass = "action-$($Item.Severity.ToLowerInvariant())"

                # Always HTML-encode values before inserting them into the HTML.
                # This protects the report if a finding contains characters like
                # <, >, &, quotes, or other markup-looking text.
                $SafeSeverity = ConvertTo-HtmlSafeText $Item.Severity
                $SafeTitle = ConvertTo-HtmlSafeText $Item.Title
                $SafeCategory = ConvertTo-HtmlSafeText $Item.Category
                $SafeDetail = ConvertTo-HtmlSafeText $Item.Detail
                $SafeSuggestedAction = ConvertTo-HtmlSafeText $Item.SuggestedAction

                # Detail is optional. Most findings do not need a second detail
                # line, but the summarized software action uses it to point back
                # to the full Software Readiness list.
                $DetailHtml = ""
                if (-not [string]::IsNullOrWhiteSpace($Item.Detail)) {
                    $DetailHtml = "<p class=`"action-detail`">$SafeDetail</p>"
                }

                # This is the individual ticket-style action card.
                # The severity badge and left border provide quick visual context.
                # The category label preserves the original evidence domain even
                # though the overall queue is now sorted by severity first.
                $ItemBlocks += @"
                    <article class="action-item $SeverityClass">
                        <div class="action-header">
                            <span class="action-severity">$SafeSeverity</span>
                            <strong>$SafeTitle</strong>
                        </div>
                        <div class="action-meta">Category: $SafeCategory</div>
                        $DetailHtml
                        <div class="action-suggestion">
                            <span class="action-label">Suggested Action</span>
                            <p>$SafeSuggestedAction</p>
                        </div>
                    </article>
"@
            }

            $SafeHeading = ConvertTo-HtmlSafeText $PriorityGroup.Heading
            $SafeSummary = ConvertTo-HtmlSafeText $PriorityGroup.Summary
            $SafeCount = ConvertTo-HtmlSafeText "$($SeverityItems.Count) action(s)"
            $ItemsHtml = $ItemBlocks -join "`n"

            # This is the severity wrapper, such as Failed Actions or Warnings.
            # The header count makes the queue easier to scan without changing the
            # underlying action data.
            $GroupBlocks += @"
                <div class="action-group action-priority-group">
                    <div class="action-group-header">
                        <div>
                            <h3>$SafeHeading</h3>
                            <p>$SafeSummary</p>
                        </div>
                        <span class="action-group-count">$SafeCount</span>
                    </div>
$ItemsHtml
                </div>
"@
        }

        $GroupsHtml = $GroupBlocks -join "`n"

        # Final Recommended Actions section inserted into the main HTML template.
        return @"
        <section id="recommended-actions" class="card section">
            <div class="section-title">
                <h2>Recommended Actions</h2>
                <p>Grouped findings that need attention, prioritized for local triage.</p>
            </div>
            <div class="action-summary-strip" aria-label="Recommended Actions summary">
                <span class="action-summary-chip"><strong>$TotalActionCount</strong> Action Item(s)</span>
                <span class="action-summary-chip action-summary-fail"><strong>$FailActionCount</strong> FAIL</span>
                <span class="action-summary-chip action-summary-warn"><strong>$WarnActionCount</strong> WARN</span>
            </div>
            <div class="action-queue">
$GroupsHtml
            </div>
        </section>
"@
    }

    # Builds the v0.24 System evidence dashboard section.
    #
    # Why this exists:
    # - The System section now groups existing endpoint evidence into familiar
    #   triage blocks: platform, vital signs, storage, process health, and core
    #   service trust.
    # - This is presentation-only. It reuses findings that were already written
    #   to the report and does not run additional system checks.
    # - Keeping this in its own helper makes the v0.24 change easier to audit or
    #   adjust without touching the console/TXT reporting path.
    function New-ArcForgeSystemEvidenceHtml {
        param (
            [string]$ComputerName,
            [string]$CurrentUser,
            [object[]]$SystemLines,
            [object[]]$UptimeLines,
            [object[]]$StorageLines,
            [object[]]$ProcessLines,
            [object[]]$ServiceLines
        )

        # Converts one raw finding line like:
        # [OK] OS Name: Microsoft Windows 10...
        # into a small object the HTML renderer can place in a key/value row.
        function ConvertTo-ArcForgeSystemEvidenceRecord {
            param (
                [string]$Line
            )

            if ([string]::IsNullOrWhiteSpace($Line)) {
                return $null
            }

            $Pattern = '^\[(OK|WARN|FAIL)\]\s+(.+?:)\s*(.*)$'
            if ($Line -notmatch $Pattern) {
                return $null
            }

            return [pscustomobject]@{
                Status = $Matches[1]
                Label  = $Matches[2].Trim()
                Value  = $Matches[3].Trim()
            }
        }

        # Looks up the first finding with a matching label in an existing section.
        # Missing rows are rendered as muted placeholders so the HTML remains
        # stable even if a check fails before writing every expected line.
        function Get-ArcForgeSystemEvidenceRecord {
            param (
                [object[]]$Lines,
                [string]$Label,
                [string]$FallbackValue = "Not captured in this report."
            )

            $FlattenedLines = Get-ArcForgeFlattenedLines -Lines $Lines

            foreach ($Line in $FlattenedLines) {
                $Record = ConvertTo-ArcForgeSystemEvidenceRecord -Line $Line
                if ($null -ne $Record -and $Record.Label -eq $Label) {
                    return $Record
                }
            }

            return [pscustomobject]@{
                Status = "UNKNOWN"
                Label  = $Label
                Value  = $FallbackValue
            }
        }

        # Renders a single compact status-first key/value row.
        # The status class only affects the HTML report and does not change
        # readiness scoring or report data.
        function New-ArcForgeSystemEvidenceRowHtml {
            param (
                [object]$Record,
                [string]$DisplayLabel
            )

            $Status = if ($Record.Status) { [string]$Record.Status } else { "UNKNOWN" }
            $StatusClass = switch ($Status) {
                "OK"      { "system-status-ok" }
                "WARN"    { "system-status-warn" }
                "FAIL"    { "system-status-fail" }
                default   { "system-status-unknown" }
            }

            $Label = if ([string]::IsNullOrWhiteSpace($DisplayLabel)) { $Record.Label } else { $DisplayLabel }
            $SafeStatus = ConvertTo-HtmlSafeText $Status
            $SafeLabel = ConvertTo-HtmlSafeText (($Label -replace ':$', '').Trim())
            $SafeValue = ConvertTo-HtmlSafeText $Record.Value

            return @"
                    <div class="system-evidence-row">
                        <span class="system-status-pill $StatusClass">$SafeStatus</span>
                        <span class="system-evidence-label">$SafeLabel</span>
                        <span class="system-evidence-value">$SafeValue</span>
                    </div>
"@
        }

        # Renders a compact status + label row for snapshot cards.
        # Use this when the overview should communicate the signal without
        # cramming long evidence values into a narrow responsive card.
        # The full evidence value should remain available in the matching
        # details section.
        function New-ArcForgeSystemStatusLabelRowHtml {
            param (
                [object]$Record,
                [string]$DisplayLabel
            )

            $Status = if ($Record.Status) { [string]$Record.Status } else { "UNKNOWN" }
            $StatusClass = switch ($Status) {
                "OK"      { "system-status-ok" }
                "WARN"    { "system-status-warn" }
                "FAIL"    { "system-status-fail" }
                default   { "system-status-unknown" }
            }

            $Label = if ([string]::IsNullOrWhiteSpace($DisplayLabel)) { $Record.Label } else { $DisplayLabel }
            $SafeStatus = ConvertTo-HtmlSafeText $Status
            $SafeLabel = ConvertTo-HtmlSafeText (($Label -replace ':$', '').Trim())

            return @"
                    <div class="system-status-label-row">
                        <span class="system-status-pill $StatusClass">$SafeStatus</span>
                        <span class="system-evidence-label">$SafeLabel</span>
                    </div>
"@
        }

        # Renders identity/platform evidence without a health-style OK pill.
        # Endpoint identity fields are evidence capture values, not pass/fail
        # health checks, so this quieter row avoids implying a status verdict.
        function New-ArcForgeSystemEvidenceOnlyRowHtml {
            param (
                [object]$Record,
                [string]$DisplayLabel
            )

            $Label = if ([string]::IsNullOrWhiteSpace($DisplayLabel)) { $Record.Label } else { $DisplayLabel }
            $Value = if ($Record -and -not [string]::IsNullOrWhiteSpace([string]$Record.Value)) {
                [string]$Record.Value
            }
            else {
                "Evidence not captured."
            }

            if ($Value -eq "Not captured in this report.") {
                $Value = "Evidence not captured."
            }

            $ValueClass = if ($Value -eq "Evidence not captured.") {
                "system-evidence-value system-evidence-value-missing"
            }
            else {
                "system-evidence-value"
            }

            $SafeLabel = ConvertTo-HtmlSafeText (($Label -replace ':$', '').Trim())
            $SafeValue = ConvertTo-HtmlSafeText $Value

            return @"
                    <div class="system-evidence-row system-evidence-row-informational">
                        <span class="system-evidence-label">$SafeLabel</span>
                        <span class="$ValueClass">$SafeValue</span>
                    </div>
"@
        }

        # Builds a System snapshot panel. Optional anchor-style footer links let
        # the snapshot stay compact while still giving technicians a clear path
        # to deeper static evidence sections later in the same HTML report.
        function New-ArcForgeSystemPanelHtml {
            param (
                [string]$Title,
                [string]$Description,
                [string]$RowsHtml,
                [string]$ExtraClass = "",
                [string]$LinkHref = "",
                [string]$LinkText = ""
            )

            $SafeTitle = ConvertTo-HtmlSafeText $Title
            $SafeDescription = ConvertTo-HtmlSafeText $Description
            $PanelClass = "system-evidence-panel"

            if (-not [string]::IsNullOrWhiteSpace($ExtraClass)) {
                $PanelClass = "$PanelClass $ExtraClass"
            }

            $LinkHtml = ""
            if (-not [string]::IsNullOrWhiteSpace($LinkHref) -and -not [string]::IsNullOrWhiteSpace($LinkText)) {
                $SafeLinkHref = ConvertTo-HtmlSafeText $LinkHref
                $SafeLinkText = ConvertTo-HtmlSafeText $LinkText
                $LinkHtml = @"
                    <div class="system-panel-footer">
                        <a class="system-panel-link" href="$SafeLinkHref"><span class="system-panel-link-text">$SafeLinkText</span></a>
                    </div>
"@
            }

            return @"
                <article class="$PanelClass">
                    <div class="system-panel-header">
                        <h3>$SafeTitle</h3>
                        <p>$SafeDescription</p>
                    </div>
                    <div class="system-evidence-rows">
$RowsHtml
                    </div>
$LinkHtml
                </article>
"@
        }

        # Wraps a System body block in a native collapsible card.
        # This keeps the System section segmented without adding JavaScript or
        # changing the underlying evidence/check logic.
        function New-ArcForgeSystemCollapsibleCardHtml {
            param (
                [string]$Id = "",
                [string]$Title,
                [string]$Description,
                [string]$BodyHtml,
                [string]$ExtraClass = "",
                [bool]$OpenByDefault = $false
            )

            $SafeTitle = ConvertTo-HtmlSafeText $Title
            $SafeDescription = ConvertTo-HtmlSafeText $Description
            $CardClass = "system-collapsible-card"
            $IdAttribute = ""
            $OpenAttribute = ""

            if (-not [string]::IsNullOrWhiteSpace($ExtraClass)) {
                $CardClass = "$CardClass $ExtraClass"
            }

            if (-not [string]::IsNullOrWhiteSpace($Id)) {
                $SafeId = ConvertTo-HtmlSafeText $Id
                $IdAttribute = " id=`"$SafeId`""
            }

            if ($OpenByDefault) {
                $OpenAttribute = " open"
            }

            return @"
                <details$IdAttribute class="$CardClass"$OpenAttribute>
                    <summary class="system-collapsible-summary">
                        <span class="system-collapsible-title">$SafeTitle</span>
                        <span class="system-collapsible-chevron" aria-hidden="true">›</span>
                    </summary>
                    <div class="system-collapsible-card-body">
                        <p class="system-collapsible-description">$SafeDescription</p>
$BodyHtml
                    </div>
                </details>
"@
        }

        # Builds a detail anchor section from existing report lines only.
        # These sections are intentionally simple and static: the snapshot cards
        # link here when a tech wants more evidence without requiring JavaScript.
        function New-ArcForgeSystemDetailSectionHtml {
            param (
                [string]$Id,
                [string]$Title,
                [string]$Description,
                [object[]]$Lines
            )

            $DetailRows = @()

            foreach ($Line in (Get-ArcForgeFlattenedLines -Lines $Lines)) {
                $Record = ConvertTo-ArcForgeSystemEvidenceRecord -Line $Line
                if ($null -ne $Record) {
                    $DetailRows += New-ArcForgeSystemEvidenceRowHtml -Record $Record
                }
            }

            if (-not $DetailRows -or $DetailRows.Count -eq 0) {
                $DetailRows += @"
                    <div class="system-detail-empty muted">No detail lines captured for this subsection.</div>
"@
            }

            $DetailRowsHtml = $DetailRows -join "`n"

            $DetailBodyHtml = @"
                        <div class="system-evidence-rows">
$DetailRowsHtml
                        </div>
"@

            return New-ArcForgeSystemCollapsibleCardHtml -Id $Id -Title $Title -Description $Description -BodyHtml $DetailBodyHtml -ExtraClass "system-detail-collapsible-card"
        }

        $ComputerValue = if ([string]::IsNullOrWhiteSpace($ComputerName)) { "Evidence not captured." } else { $ComputerName }
        $CurrentUserValue = if ([string]::IsNullOrWhiteSpace($CurrentUser)) { "Evidence not captured." } else { $CurrentUser }
        $ComputerRecord = [pscustomobject]@{ Status = "INFO"; Label = "Computer Name:"; Value = $ComputerValue }
        $UserRecord = [pscustomobject]@{ Status = "INFO"; Label = "Current User:"; Value = $CurrentUserValue }
        $OsNameRecord = Get-ArcForgeSystemEvidenceRecord -Lines $SystemLines -Label "OS Name:" -FallbackValue "Evidence not captured."
        $OsVersionRecord = Get-ArcForgeSystemEvidenceRecord -Lines $SystemLines -Label "OS Version:" -FallbackValue "Evidence not captured."
        $ArchitectureRecord = Get-ArcForgeSystemEvidenceRecord -Lines $SystemLines -Label "Architecture:" -FallbackValue "Evidence not captured."

        $EndpointRows = @(
            New-ArcForgeSystemEvidenceOnlyRowHtml -Record $ComputerRecord -DisplayLabel "Computer Name"
            New-ArcForgeSystemEvidenceOnlyRowHtml -Record $UserRecord -DisplayLabel "Current User"
            New-ArcForgeSystemEvidenceOnlyRowHtml -Record $OsNameRecord -DisplayLabel "OS Name"
            New-ArcForgeSystemEvidenceOnlyRowHtml -Record $OsVersionRecord -DisplayLabel "OS Version"
            New-ArcForgeSystemEvidenceOnlyRowHtml -Record $ArchitectureRecord -DisplayLabel "Architecture"
        ) -join "`n"

        $LastBootRecord = Get-ArcForgeSystemEvidenceRecord -Lines $UptimeLines -Label "Last Boot:"
        $UptimeDaysRecord = Get-ArcForgeSystemEvidenceRecord -Lines $UptimeLines -Label "Uptime Days:"

        $VitalRows = @(
            New-ArcForgeSystemStatusLabelRowHtml -Record $LastBootRecord -DisplayLabel "Last Boot"
            New-ArcForgeSystemStatusLabelRowHtml -Record $UptimeDaysRecord -DisplayLabel "Uptime"
        ) -join "`n"

        $DriveRecord = Get-ArcForgeSystemEvidenceRecord -Lines $StorageLines -Label "Drive:"
        $TotalSizeRecord = Get-ArcForgeSystemEvidenceRecord -Lines $StorageLines -Label "Total Size:"
        $FreeSpaceRecord = Get-ArcForgeSystemEvidenceRecord -Lines $StorageLines -Label "Free Space:"
        $FreePercent = $null
        $UsedPercent = $null
        $TotalSizeGb = $null
        $FreeSpaceGb = $null
        $UsedSpaceGb = $null

        if ($FreeSpaceRecord.Value -match '\((?<Percent>[0-9]+(\.[0-9]+)?)%\)') {
            $FreePercent = [double]$Matches.Percent
            $UsedPercent = [math]::Max(0, [math]::Min(100, (100 - $FreePercent)))
        }

        if ($TotalSizeRecord.Value -match '(?<Total>[0-9]+(\.[0-9]+)?)\s*GB') {
            $TotalSizeGb = [double]$Matches.Total
        }

        if ($FreeSpaceRecord.Value -match '(?<Free>[0-9]+(\.[0-9]+)?)\s*GB\s*free') {
            $FreeSpaceGb = [double]$Matches.Free
        }

        if ($null -ne $TotalSizeGb -and $null -ne $FreeSpaceGb) {
            $UsedSpaceGb = [math]::Max(0, ($TotalSizeGb - $FreeSpaceGb))
        }

        $SafeDriveValue = ConvertTo-HtmlSafeText $DriveRecord.Value

        # The summary card label already says "Free Space", so the display
        # value removes the redundant word "free" while preserving the amount
        # and percentage captured by the existing storage check.
        $FreeSpaceDisplayValue = ($FreeSpaceRecord.Value -replace '\s+free\s*\(', ' (')
        $SafeFreeSpaceValue = ConvertTo-HtmlSafeText $FreeSpaceDisplayValue
        $UsedSummaryText = "Used space not calculated."

        if ($null -ne $UsedSpaceGb -and $null -ne $TotalSizeGb) {
            $UsedSpaceText = $UsedSpaceGb.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
            $TotalSizeText = $TotalSizeGb.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
            $UsedSummaryText = "Used $UsedSpaceText GB / $TotalSizeText GB"
        }

        $SafeUsedSummaryText = ConvertTo-HtmlSafeText $UsedSummaryText
        $StorageMeterClass = switch ($FreeSpaceRecord.Status) {
            "OK"      { "system-meter-ok" }
            "WARN"    { "system-meter-warn" }
            "FAIL"    { "system-meter-fail" }
            default   { "system-meter-unknown" }
        }

        $StorageMeterHtml = @"
                    <div class="system-storage-meter-block">
                        <div class="system-storage-meter-empty" aria-label="Primary drive used space unavailable"></div>
                    </div>
"@

        $StoragePercentHtml = @"
                    <div class="system-storage-percent-row muted">Used and free percentages were not captured.</div>
"@

        if ($null -ne $FreePercent -and $null -ne $UsedPercent) {
            $FreePercentText = $FreePercent.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
            $UsedPercentText = $UsedPercent.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
            $SafeFreePercent = ConvertTo-HtmlSafeText $FreePercentText
            $SafeUsedPercent = ConvertTo-HtmlSafeText $UsedPercentText

            # The inline width is generated at report time and stays static in
            # the saved HTML file. The fill represents consumed space so the card
            # follows the familiar Windows/RMM storage meter pattern.
            $StorageMeterHtml = @"
                    <div class="system-storage-meter-block">
                        <div class="system-storage-meter" aria-label="Primary drive used space $SafeUsedPercent percent">
                            <div class="system-storage-meter-fill $StorageMeterClass" style="width: $SafeUsedPercent%;"></div>
                        </div>
                    </div>
"@

            $StoragePercentHtml = @"
                    <div class="system-storage-legend-row">
                        <span class="system-storage-legend-item"><span class="system-storage-legend-marker system-storage-legend-used $StorageMeterClass"></span>$SafeUsedPercent% Used</span>
                        <span class="system-storage-legend-item"><span class="system-storage-legend-marker system-storage-legend-free"></span>$SafeFreePercent% Free</span>
                    </div>
"@
        }

        $StorageRows = @"
                    <div class="system-storage-widget">
                        <div class="system-storage-drive-row">
                            <div class="system-storage-drive-name">$SafeDriveValue</div>
                            <div class="system-storage-used-summary">$SafeUsedSummaryText</div>
                        </div>
$StorageMeterHtml
$StoragePercentHtml
                        <div class="system-storage-free-row">Free Space: $SafeFreeSpaceValue</div>
                    </div>
"@

        $HungAppsRecord = Get-ArcForgeSystemEvidenceRecord -Lines $ProcessLines -Label "Hung Apps:"
        $HungAppItems = @()

        if ($HungAppsRecord.Status -ne "OK" -and $HungAppsRecord.Value -match ':\s*(?<Names>.+)$') {
            $HungAppItems = @(
                foreach ($Name in ($Matches.Names -split ',' | Select-Object -First 5)) {
                    $CleanName = $Name.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($CleanName)) {
                        $CleanName
                    }
                }
            )
        }

        $HungAppsSnapshotHtml = ""
        if ($HungAppItems.Count -gt 0) {
            $HungAppsListItems = @(
                foreach ($Name in $HungAppItems) {
                    $SafeName = ConvertTo-HtmlSafeText $Name
                    "<li>$SafeName</li>"
                }
            ) -join "`n"

            $HungAppsSnapshotHtml = @"
                            <ul class="system-compact-list system-compact-list-separated">
$HungAppsListItems
                            </ul>
"@
        }
        else {
            $HungAppsSnapshotHtml = New-ArcForgeSystemStatusLabelRowHtml -Record $HungAppsRecord -DisplayLabel "Hung Apps"
        }

        $TopMemoryRecords = @(
            foreach ($Line in (Get-ArcForgeFlattenedLines -Lines $ProcessLines)) {
                $Record = ConvertTo-ArcForgeSystemEvidenceRecord -Line $Line
                if ($null -ne $Record -and $Record.Label -eq "Top Memory:") {
                    $Record
                }
            }
        ) | Select-Object -First 5

        $TopMemoryRows = @()
        $Index = 1
        foreach ($Record in $TopMemoryRecords) {
            $SafeIndex = ConvertTo-HtmlSafeText ([string]$Index)
            $SafeValue = ConvertTo-HtmlSafeText $Record.Value
            $TopMemoryRows += @"
                                    <tr>
                                        <td>$SafeIndex</td>
                                        <td>$SafeValue</td>
                                    </tr>
"@
            $Index++
        }

        if (-not $TopMemoryRows -or $TopMemoryRows.Count -eq 0) {
            $TopMemoryRows += @"
                                    <tr>
                                        <td colspan="2" class="muted">No top memory consumers captured.</td>
                                    </tr>
"@
        }

        $TopMemoryRowsHtml = $TopMemoryRows -join "`n"
        $ProcessRows = @"
                    <div class="system-process-snapshot-grid">
                        <div class="system-process-snapshot-card">
                            <div class="system-mini-table-title">Hung Applications</div>
$HungAppsSnapshotHtml
                        </div>
                        <div class="system-process-snapshot-card">
                            <div class="system-mini-table-title">Top 5 Memory Consumers</div>
                            <table class="system-mini-table">
                                <thead>
                                    <tr>
                                        <th>#</th>
                                        <th>Process</th>
                                    </tr>
                                </thead>
                                <tbody>
$TopMemoryRowsHtml
                                </tbody>
                            </table>
                        </div>
                    </div>
"@

        $ServiceLabels = @("Event Log:", "WMI:", "Workstation:", "DNS Client:")
        $ServiceCells = @()

        foreach ($Label in $ServiceLabels) {
            $Record = Get-ArcForgeSystemEvidenceRecord -Lines $ServiceLines -Label $Label
            $Status = if ($Record.Status) { [string]$Record.Status } else { "UNKNOWN" }
            $StatusClass = switch ($Status) {
                "OK"      { "system-service-ok" }
                "WARN"    { "system-service-warn" }
                "FAIL"    { "system-service-fail" }
                default   { "system-service-unknown" }
            }
            $SafeStatus = ConvertTo-HtmlSafeText $Status
            $SafeLabel = ConvertTo-HtmlSafeText (($Record.Label -replace ':$', '').Trim())
            $SafeValue = ConvertTo-HtmlSafeText $Record.Value

            $ServiceCells += @"
                        <div class="system-service-cell $StatusClass">
                            <span class="system-service-name">$SafeLabel</span>
                            <span class="system-service-status">$SafeStatus</span>
                            <span class="system-service-detail">$SafeValue</span>
                        </div>
"@
        }

        $ServiceRows = @"
                    <div class="system-service-matrix">
$($ServiceCells -join "`n")
                    </div>
"@

        $Panels = @(
            New-ArcForgeSystemPanelHtml -Title "Endpoint Platform" -Description "Local identity and operating system evidence." -RowsHtml $EndpointRows -ExtraClass "system-panel-wide" -LinkHref "#system-endpoint-platform-details" -LinkText "Endpoint Platform Details"
            New-ArcForgeSystemPanelHtml -Title "Vital Signs" -Description "Boot and uptime indicators for quick stability review." -RowsHtml $VitalRows -LinkHref "#system-vital-signs-details" -LinkText "Vital Signs Details"
            New-ArcForgeSystemPanelHtml -Title "Primary Drive Storage" -Description "Primary system drive capacity." -RowsHtml $StorageRows -LinkHref "#system-storage-details" -LinkText "Storage Details"
            New-ArcForgeSystemPanelHtml -Title "Process Health" -Description "Snapshot of hung applications and the top five memory consumers." -RowsHtml $ProcessRows -ExtraClass "system-panel-wide" -LinkHref "#system-process-details" -LinkText "Process Health Details"
            New-ArcForgeSystemPanelHtml -Title "Core Services Matrix" -Description "Critical Windows service pipes that affect triage trust." -RowsHtml $ServiceRows -ExtraClass "system-panel-wide" -LinkHref "#system-core-services-details" -LinkText "Core Services Details"
        ) -join "`n"

        # v0.24 Part 3 anchor alignment.
        # Every System child link in the Report Navigation sidebar must point to
        # a real detail section in the static HTML body. If a sidebar link points
        # to a missing id, browsers can handle focus/hash navigation differently,
        # which makes the gray click/focus box feel inconsistent during testing.
        $EndpointDetailsHtml = New-ArcForgeSystemDetailSectionHtml -Id "system-endpoint-platform-details" -Title "Endpoint Platform Details" -Description "Endpoint identity and operating system evidence captured from the current System check plus the report header context." -Lines @(
            "[INFO] Computer Name: $ComputerValue"
            "[INFO] Current User: $CurrentUserValue"
            $SystemLines
        )
        $VitalDetailsHtml = New-ArcForgeSystemDetailSectionHtml -Id "system-vital-signs-details" -Title "Vital Signs Details" -Description "Boot and uptime evidence captured by the current ArcForge uptime check. This section reports observed availability signals only; it does not diagnose the cause of long uptime or recent restarts." -Lines $UptimeLines
        $StorageDetailsHtml = New-ArcForgeSystemDetailSectionHtml -Id "system-storage-details" -Title "Storage Details" -Description "Storage evidence captured by the current ArcForge storage check. Future multi-drive support can expand here without crowding the System snapshot." -Lines $StorageLines
        $ProcessDetailsHtml = New-ArcForgeSystemDetailSectionHtml -Id "system-process-details" -Title "Process Health Details" -Description "Process evidence captured by the current ArcForge process checks, including hung application status and the top memory consumers." -Lines $ProcessLines
        $ServiceDetailsHtml = New-ArcForgeSystemDetailSectionHtml -Id "system-core-services-details" -Title "Core Services Details" -Description "Core Windows service evidence captured by the current ArcForge service checks. This confirms observed service state only; it does not compare against a service baseline or drift policy." -Lines $ServiceLines

        $SystemOverviewBodyHtml = @"
                        <div class="system-evidence-grid">
$Panels
                        </div>
"@

        $SystemOverviewHtml = New-ArcForgeSystemCollapsibleCardHtml -Title "System Overview" -Description "Snapshot cards for endpoint platform, vital signs, storage, process health, and core service evidence." -BodyHtml $SystemOverviewBodyHtml -ExtraClass "system-overview-card" -OpenByDefault $true

        return @"
        <section id="system" class="section system-evidence">
            <div class="section-title system-section-title">
                <h2>System</h2>
                <p>Endpoint evidence grouped for fast offline triage. System Overview opens by default for quick triage; deeper System details start collapsed and can be expanded without JavaScript.</p>
            </div>
            <div class="system-collapsible-stack" aria-label="System evidence sections">
$SystemOverviewHtml
$EndpointDetailsHtml
$VitalDetailsHtml
$StorageDetailsHtml
$ProcessDetailsHtml
$ServiceDetailsHtml
            </div>
        </section>
"@
    }

    # Builds the three compact status segments shown beside readiness-domain
    # links in the HTML report sidebar.
    #
    # Why this exists:
    # - v0.19 is still a presentation-layer release.
    # - The sidebar segments give the report a quick dashboard-style glance
    #   without adding JavaScript, external dependencies, or a new GUI layer.
    # - This helper only converts an existing readiness status into small HTML
    #   spans. It does not inspect the computer or rerun any health checks.
    #
    # Input:
    # - A readiness status from Get-ArcForgeSectionReadiness:
    #   Critical, Attention, OK, or No Data.
    #
    # Output:
    # - A string containing three small <span> elements.
    #
    # Important:
    # - This is presentation-only.
    # - This does not change check logic, scoring, console output, or TXT output.
    # - The sidebar status should always match the Readiness Overview card that
    #   was built from the same readiness object.
    function New-ArcForgeSidebarStatusSegmentsHtml {
        param (
            [string]$Status
        )

        $SegmentClass = "sidebar-segment-empty"
        $FilledSegments = 0

        switch ($Status) {
            "Critical" {
                $SegmentClass = "sidebar-segment-critical"
                $FilledSegments = 1
            }
            "Attention" {
                $SegmentClass = "sidebar-segment-attention"
                $FilledSegments = 2
            }
            "OK" {
                $SegmentClass = "sidebar-segment-ok"
                $FilledSegments = 3
            }
            default {
                $SegmentClass = "sidebar-segment-empty"
                $FilledSegments = 0
            }
        }

        $Segments = @()

        for ($Index = 1; $Index -le 3; $Index++) {
            if ($Index -le $FilledSegments) {
                $Segments += "<span class=""sidebar-segment $SegmentClass""></span>"
            }
            else {
                $Segments += "<span class=""sidebar-segment sidebar-segment-empty""></span>"
            }
        }

        return ($Segments -join "")
    }

    # Builds the static sidebar navigation used by the HTML report.
    #
    # Why this exists:
    # - v0.18 added quick-jump navigation for the major report sections.
    # - v0.19 reuses the existing Readiness Overview data to add small status
    #   segments beside the five primary readiness domains only.
    # - This helper keeps the navigation markup in one small place instead of
    #   scattering repeated <a> tags throughout the main HTML template.
    #
    # Input:
    # - ReadinessCards are the same objects used by New-ArcForgeReadinessOverviewHtml.
    # - The cards are calculated once, then reused by both the Readiness Overview
    #   and this sidebar navigation. That keeps both views in sync.
    #
    # Important:
    # - These are normal internal anchor links like href="#network".
    # - The status segments are visual/presentation-only.
    # - No JavaScript is used.
    # - No external dependencies are used.
    # - This does not change any check logic, console output, or TXT output.
    #
    # Troubleshooting rule:
    # - Every href="#section-name" in this helper must match an id="section-name"
    #   somewhere in the HTML template below.
    # - Sidebar status segments should only appear for System, Network,
    #   Software Readiness, Security, and Updates.
    # - If a segment does not match the Readiness Overview card, inspect the
    #   readiness card Name values first.
    #
    # Output:
    # - A string containing the complete sidebar <aside> block.
    function New-ArcForgeReportNavigationHtml {
        param (
            [object[]]$ReadinessCards
        )

        $ReadinessByName = @{}

        foreach ($Card in $ReadinessCards) {
            $ReadinessByName[$Card.Name] = $Card
        }

        $NavigationItems = @(
            [pscustomobject]@{ Label = "Report Summary";       Anchor = "report-summary";       ShowStatus = $false }
            [pscustomobject]@{ Label = "Incident Summary";     Anchor = "incident-summary";     ShowStatus = $false }
            [pscustomobject]@{ Label = "Readiness Overview";   Anchor = "readiness-overview";   ShowStatus = $false }
            [pscustomobject]@{ Label = "System";               Anchor = "system";               ShowStatus = $true  }
            [pscustomobject]@{ Label = "Network";              Anchor = "network";              ShowStatus = $true  }
            [pscustomobject]@{ Label = "Software Readiness";   Anchor = "software-readiness";   ShowStatus = $true  }
            [pscustomobject]@{ Label = "Security";             Anchor = "security";             ShowStatus = $true  }
            [pscustomobject]@{ Label = "Updates";              Anchor = "updates";              ShowStatus = $true  }
            [pscustomobject]@{ Label = "Recommended Actions";  Anchor = "recommended-actions";  ShowStatus = $false }
            [pscustomobject]@{ Label = "Raw Findings";         Anchor = "raw-findings";         ShowStatus = $false }
        )

        $NavigationLinks = @()

        foreach ($Item in $NavigationItems) {
            $SafeLabel = ConvertTo-HtmlSafeText $Item.Label
            $SafeAnchor = ConvertTo-HtmlSafeText $Item.Anchor

            # v0.24 Part 2:
            # System is the first sidebar section to use native, no-JavaScript
            # parent/child navigation. The parent row expands or collapses the
            # System tree, while the child links jump to the System snapshot and
            # detail anchors.
            #
            # Important:
            # - This is HTML presentation only.
            # - It does not rerun checks.
            # - It does not change readiness scoring.
            # - It does not change console output or TXT report output.
            if ($Item.Label -eq "System" -and $Item.ShowStatus -and $ReadinessByName.ContainsKey($Item.Label)) {
                $Card = $ReadinessByName[$Item.Label]
                $SafeStatus = ConvertTo-HtmlSafeText $Card.Status
                $SegmentsHtml = New-ArcForgeSidebarStatusSegmentsHtml -Status $Card.Status

                $NavigationLinks += @"
                <details class="sidebar-section-group" open>
                    <summary class="sidebar-section-summary" title="$SafeLabel readiness: $SafeStatus" aria-label="$SafeLabel readiness: $SafeStatus">
                        <span class="sidebar-section-summary-label">$SafeLabel</span>
                        <span class="sidebar-status-segments" aria-hidden="true">$SegmentsHtml</span>
                    </summary>
                    <a class="sidebar-section-subitem" href="#$SafeAnchor">System Overview</a>
                    <a class="sidebar-section-subitem" href="#system-endpoint-platform-details">Endpoint Platform Details</a>
                    <a class="sidebar-section-subitem" href="#system-vital-signs-details">Vital Signs Details</a>
                    <a class="sidebar-section-subitem" href="#system-storage-details">Storage Details</a>
                    <a class="sidebar-section-subitem" href="#system-process-details">Process Health Details</a>
                    <a class="sidebar-section-subitem" href="#system-core-services-details">Core Services Details</a>
                </details>
"@
                continue
            }

            if ($Item.ShowStatus -and $ReadinessByName.ContainsKey($Item.Label)) {
                $Card = $ReadinessByName[$Item.Label]
                $SafeStatus = ConvertTo-HtmlSafeText $Card.Status
                $SegmentsHtml = New-ArcForgeSidebarStatusSegmentsHtml -Status $Card.Status

                $NavigationLinks += @"
                <a class="sidebar-link sidebar-link-with-status" href="#$SafeAnchor" title="$SafeLabel readiness: $SafeStatus" aria-label="$SafeLabel readiness: $SafeStatus">
                    <span class="sidebar-link-label">$SafeLabel</span>
                    <span class="sidebar-status-segments" aria-hidden="true">$SegmentsHtml</span>
                </a>
"@
            }
            else {
                $NavigationLinks += "                <a class=""sidebar-link"" href=""#$SafeAnchor"">$SafeLabel</a>"
            }
        }

        $NavigationLinksHtml = $NavigationLinks -join "`n"

        return @"
        <aside class="report-sidebar">
            <div class="sidebar-title">Report Navigation</div>
            <div class="sidebar-subtitle">Jump to a major report section.</div>
            <nav class="sidebar-nav" aria-label="ArcForge report sections">
$NavigationLinksHtml
            </nav>
        </aside>
"@
    }

    $ReportSections = Get-ArcForgeReportSections -ReportLines $ReportLines

    $SystemLines = @(
        $ReportSections["SYSTEM"]
        $ReportSections["UPTIME"]
        $ReportSections["PROCESSES"]
        $ReportSections["SERVICES"]
        $ReportSections["STORAGE"]
    )

    $NetworkLines = $ReportSections["NETWORK"]
    $SoftwareLines = $ReportSections["SOFTWARE"]
    $SecurityLines = $ReportSections["SECURITY"]
    $UpdatesLines = $ReportSections["UPDATES"]

    $SystemEvidenceHtml = New-ArcForgeSystemEvidenceHtml `
        -ComputerName $ComputerName `
        -CurrentUser $CurrentUser `
        -SystemLines $ReportSections["SYSTEM"] `
        -UptimeLines $ReportSections["UPTIME"] `
        -StorageLines $ReportSections["STORAGE"] `
        -ProcessLines $ReportSections["PROCESSES"] `
        -ServiceLines $ReportSections["SERVICES"]

    $NetworkFindingsHtml = ConvertTo-ArcForgeHtmlFindingList -Lines $NetworkLines
    $SoftwareFindingsHtml = ConvertTo-ArcForgeHtmlFindingList -Lines $SoftwareLines
    $SecurityFindingsHtml = ConvertTo-ArcForgeHtmlFindingList -Lines $SecurityLines
    $UpdatesFindingsHtml = ConvertTo-ArcForgeHtmlFindingList -Lines $UpdatesLines

    # Build the shared readiness card data once.
    #
    # Why this exists:
    # - The Readiness Overview cards and the v0.19 sidebar readiness segments
    #   should describe the same five readiness domains.
    # - Calculating these objects once prevents the sidebar and overview cards
    #   from drifting out of sync later.
    #
    # Important:
    # - This reuses the existing readiness helper.
    # - This does not rerun health checks.
    # - This does not change console output or TXT report output.
    $ReadinessCards = @(
        Get-ArcForgeSectionReadiness -Name "System" -Lines $SystemLines
        Get-ArcForgeSectionReadiness -Name "Network" -Lines $NetworkLines
        Get-ArcForgeSectionReadiness -Name "Software Readiness" -Lines $SoftwareLines
        Get-ArcForgeSectionReadiness -Name "Security" -Lines $SecurityLines
        Get-ArcForgeSectionReadiness -Name "Updates" -Lines $UpdatesLines
    )

    $ReadinessOverviewHtml = New-ArcForgeReadinessOverviewHtml -ReadinessCards $ReadinessCards

    $OkCount = $CheckCounts.OK
    $WarnCount = $CheckCounts.WARN
    $FailCount = $CheckCounts.FAIL
    $TotalChecks = $OkCount + $WarnCount + $FailCount

    if ($FailCount -gt 0) {
        $OverallStatus = "Action Required"
        $StatusClass = "status-fail"
    }
    elseif ($WarnCount -gt 0) {
        $OverallStatus = "Attention Recommended"
        $StatusClass = "status-warn"
    }
    else {
        $OverallStatus = "Healthy"
        $StatusClass = "status-ok"
    }

    # Build the v0.20 Endpoint Summary badge.
    #
    # This reuses the metadata and counts already calculated for the report. It is
    # presentation-only and only affects the static HTML report's top summary area.
    $EndpointSummaryHtml = New-ArcForgeEndpointSummaryHtml `
        -ReportId $ReportId `
        -ComputerName $ComputerName `
        -CurrentUser $CurrentUser `
        -BattlestationProfile $BattlestationProfile `
        -GeneratedAt $GeneratedAt `
        -OverallStatus $OverallStatus `
        -StatusClass $StatusClass `
        -OkCount $OkCount `
        -WarnCount $WarnCount `
        -FailCount $FailCount `
        -TotalChecks $TotalChecks

    # Build the v0.17 Recommended Actions queue.
    #
    # Step 1: Convert raw WARN/FAIL report lines into simple action objects.
    # Step 2: Convert those action objects into grouped static HTML.
    #
    # This happens after the overall counts/status are calculated because the
    # action queue depends on the completed report output.
    $RecommendedActionItems = Get-ArcForgeActionItems -ReportLines $ReportLines -BattlestationProfile $BattlestationProfile
    $RecommendedActionsHtml = New-ArcForgeRecommendedActionsHtml -ActionItems $RecommendedActionItems

    # Build the v0.19 static report navigation.
    #
    # This creates the sidebar HTML once, then the main template inserts it beside
    # the report content. The same readiness objects used by the Readiness Overview
    # are passed in here so the sidebar can show compact presentation-only status
    # segments without recalculating any checks.
    $ReportNavigationHtml = New-ArcForgeReportNavigationHtml -ReadinessCards $ReadinessCards

    $RawFindings = ConvertTo-HtmlSafeText ($ReportLines -join "`r`n")

    $Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>ArcForge First Response Report - $(ConvertTo-HtmlSafeText $ReportId)</title>
    <style>
        :root {
            --bg: #f4f6f8;
            --panel: #ffffff;
            --border: #d9dee5;
            --text: #1f2933;
            --muted: #65758b;
            --ok: #1f8f4d;
            --warn: #b7791f;
            --fail: #c53030;
            --header: #111827;
            --chip: #eef2f7;
        }

        body {
            margin: 0;
            padding: 32px;
            background: var(--bg);
            color: var(--text);
            font-family: "Segoe UI", -apple-system, BlinkMacSystemFont, Roboto, sans-serif;
            line-height: 1.5;
        }

        /* v0.18 report layout shell.
           The report now has two presentation-only columns on desktop:
           a sidebar navigation panel on the left and the existing report content
           on the right. This is still a static local HTML report, not a GUI. */
        .report-shell {
            max-width: 1380px;
            margin: 0 auto;
            display: grid;
            grid-template-columns: 260px minmax(0, 1fr);
            gap: 24px;
            align-items: start;
        }

        /* Main report column.
           min-width: 0 prevents long code/raw findings text from forcing the
           grid wider than the browser window. */
        .report-main {
            min-width: 0;
        }

        /* v0.18 sidebar navigation card.
           position: sticky keeps the quick links visible while scrolling on
           desktop. It is safe because it is pure CSS and does not require JS. */
        .report-sidebar {
            position: sticky;
            top: 24px;
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 16px;
            box-shadow: 0 2px 8px rgba(15, 23, 42, 0.05);
        }

        .sidebar-title {
            font-weight: 700;
            margin-bottom: 4px;
        }

        .sidebar-subtitle {
            color: var(--muted);
            font-size: 13px;
            margin-bottom: 14px;
        }

        .sidebar-nav {
            display: grid;
            gap: 8px;
            user-select: none;
            -webkit-user-select: none;
        }

        /* v0.24 Part 3 sidebar selection guard.
           The navigation sidebar is an interaction surface, not report content.
           Disabling text selection here prevents double-clicking the System
           summary row from highlighting the label while preserving normal text
           selection throughout the report body. */
        .sidebar-nav a,
        .sidebar-section-summary,
        .sidebar-section-summary-label {
            user-select: none;
            -webkit-user-select: none;
        }

        .sidebar-link {
            color: var(--text);
            display: block;
            text-decoration: none;
            border: 1px solid transparent;
            border-radius: 10px;
            padding: 9px 10px;
            font-size: 14px;
            font-weight: 600;
        }

        /* v0.24 Part 3 sidebar interaction polish.
           These states intentionally stay scoped to the Report Navigation
           sidebar so body links and report content are not affected.

           Interaction model:
           - Hover uses a light transparent gray.
           - Focus/focus-visible/click uses a stronger gray.
           - :active gives mouse clicks the same immediate visual feedback as
             keyboard focus without requiring JavaScript active-route tracking. */
        .sidebar-link:hover {
            background: rgba(15, 23, 42, 0.06);
            border-color: rgba(15, 23, 42, 0.06);
        }

        .sidebar-link:active {
            background: rgba(15, 23, 42, 0.12);
            border-color: rgba(15, 23, 42, 0.10);
        }

        .sidebar-link:focus {
            outline: none;
        }

        /* v0.24 Part 2 System sidebar tree.
           System is a native <details>/<summary> parent so the report can
           expose subsection navigation without JavaScript.

           Interaction model:
           - The System parent row expands/collapses the subsection tree.
           - System child links jump to anchors.
           - Hover uses a light transparent gray.
           - Click uses a stronger gray while the mouse button is pressed.
           - The arrow is intentionally larger so the collapse affordance is
             easy to identify. */
        .sidebar-section-group {
            border: 0;
            margin: 0;
            padding: 0;
        }

        .sidebar-section-summary {
            align-items: center;
            border: 1px solid transparent;
            border-radius: 10px;
            color: var(--text);
            cursor: pointer;
            display: flex;
            font-size: 14px;
            font-weight: 600;
            gap: 10px;
            justify-content: space-between;
            list-style: none;
            padding: 9px 10px;
        }

        .sidebar-section-summary::-webkit-details-marker {
            display: none;
        }

        .sidebar-section-summary::before {
            content: "▸";
            display: inline-flex;
            flex: 0 0 14px;
            font-size: 13px;
            font-weight: 900;
            line-height: 1;
            transform: translateY(1px);
        }

        .sidebar-section-group[open] > .sidebar-section-summary::before {
            content: "▾";
        }

        .sidebar-section-summary:hover {
            background: rgba(15, 23, 42, 0.06);
            border-color: rgba(15, 23, 42, 0.06);
        }

        .sidebar-section-summary:active {
            background: rgba(15, 23, 42, 0.12);
            border-color: rgba(15, 23, 42, 0.10);
        }

        .sidebar-section-summary:focus {
            outline: none;
        }

        .sidebar-section-summary-label {
            color: inherit;
            flex: 1 1 auto;
            min-width: 0;
        }

        .sidebar-section-subitem {
            border: 1px solid transparent;
            border-radius: 10px;
            color: var(--text);
            display: block;
            font-size: 14px;
            font-weight: 600;
            margin-top: 4px;
            padding: 8px 10px 8px 31px;
            text-decoration: none;
        }

        .sidebar-section-subitem:hover {
            background: rgba(15, 23, 42, 0.06);
            border-color: rgba(15, 23, 42, 0.06);
        }

        .sidebar-section-subitem:active {
            background: rgba(15, 23, 42, 0.12);
            border-color: rgba(15, 23, 42, 0.10);
        }

        .sidebar-section-subitem:focus {
            outline: none;
        }

        /* v0.24 Part 3 note: persistent selected-section styling is intentionally
           not used. Sidebar feedback is limited to hover and active-click states
           so the navigation never leaves behind a gray box after interaction. */

        /* v0.19 sidebar readiness segments.
           Why this exists:
           - These tiny segments make the sidebar act more like a static triage
             dashboard while keeping the report local, self-contained, and simple.
           - They are presentation-only and reuse the same readiness data shown in
             the Readiness Overview cards.

           Important:
           - No JavaScript is involved.
           - Empty segments are muted placeholders.
           - Filled segments map to the existing readiness status:
             Critical = 1 filled segment, Attention = 2, OK = 3, No Data = 0.
           - Segment borders use a muted slate outline so empty pills stay
             visible without the harsher black border used during testing. */
        .sidebar-link-with-status {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 10px;
        }

        .sidebar-link-label {
            min-width: 0;
        }

        .sidebar-status-segments {
            display: inline-flex;
            align-items: center;
            gap: 3px;
            flex-shrink: 0;
        }

        .sidebar-segment {
            width: 8px;
            height: 14px;
            border: 1px solid rgba(100, 116, 139, 0.70);
            border-radius: 3px;
            box-sizing: border-box;
            display: inline-block;
        }

        .sidebar-segment-empty {
            background: #dbe2ea;
        }

        .sidebar-segment-ok {
            background: var(--ok);
        }

        .sidebar-segment-attention {
            background: var(--warn);
        }

        .sidebar-segment-critical {
            background: var(--fail);
        }

        /* ============================================================
           v0.18 HTML ANCHOR TARGET SPACING
           ============================================================
           These rules help the sidebar links land cleanly.

           How the sidebar jump works:
           - A sidebar link such as href="#report-summary" looks for a matching
             HTML element with id="report-summary".
           - The browser handles that jump automatically.
           - scroll-margin-top gives the jump target a little breathing room so
             the section does not land too tightly against the top of the window.

           Troubleshooting rule:
           - If a sidebar link changes the browser URL but does not visibly jump,
             confirm the matching id exists in the HTML template.
           ============================================================ */
        .section,
        .report-summary {
            scroll-margin-top: 24px;
        }

        .ticket-header {
            background: var(--header);
            color: white;
            border-radius: 14px;
            padding: 24px 28px;
            margin-bottom: 20px;
            box-shadow: 0 8px 24px rgba(15, 23, 42, 0.16);
        }

        .eyebrow {
            color: #aeb8c7;
            font-size: 13px;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            margin-bottom: 6px;
        }

        h1 {
            margin: 0;
            font-size: 28px;
            font-weight: 700;
        }

        .subtitle {
            margin-top: 8px;
            color: #d6dce8;
        }

        .status-row {
            margin-top: 18px;
        }

        .status-badge {
            display: inline-block;
            border-radius: 999px;
            padding: 7px 13px;
            font-weight: 700;
            font-size: 13px;
        }

        .status-ok {
            background: rgba(31, 143, 77, 0.16);
            color: #b7f7d1;
            border: 1px solid rgba(183, 247, 209, 0.35);
        }

        .status-warn {
            background: rgba(183, 121, 31, 0.18);
            color: #ffe0a3;
            border: 1px solid rgba(255, 224, 163, 0.35);
        }

        .status-fail {
            background: rgba(197, 48, 48, 0.18);
            color: #ffc0c0;
            border: 1px solid rgba(255, 192, 192, 0.35);
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(2, minmax(0, 1fr));
            gap: 14px;
            margin-bottom: 20px;
        }

        .card {
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 18px;
            box-shadow: 0 2px 8px rgba(15, 23, 42, 0.05);
        }

        .card h2 {
            margin: 0 0 12px 0;
            font-size: 17px;
        }

        .meta-label {
            color: var(--muted);
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 4px;
        }

        .meta-value {
            font-weight: 650;
            word-break: break-word;
        }

        /* v0.20 Endpoint Summary / ID badge.
           Why this exists:
           - This compact top panel makes the first screen feel more like a
             professional endpoint triage dashboard.
           - It replaces the older spread-out metadata card grid with one
             scannable asset-style summary.

           Important:
           - These styles affect the HTML report only.
           - They do not affect health-check logic, console output, or TXT output.
           - Keep this scoped to endpoint-* classes so later report sections are
             not accidentally redesigned during this release. */
        .endpoint-summary {
            display: grid;
            gap: 14px;
            margin-bottom: 20px;
            border-radius: 10px;
            border: 1px solid rgba(148, 163, 184, 0.22);
            box-shadow: 0 2px 8px rgba(15, 23, 42, 0.06);
        }

        .endpoint-identity {
            min-width: 0;
        }

        .endpoint-main {
            display: grid;
            grid-template-columns: minmax(0, 1.7fr) minmax(320px, 0.9fr);
            gap: 18px;
            align-items: stretch;
        }

        .endpoint-kicker {
            color: var(--muted);
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 0.08em;
            margin-bottom: 6px;
            text-transform: uppercase;
        }

        .endpoint-title-row {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
            flex-wrap: wrap;
            margin-bottom: 6px;
        }

        .endpoint-title-row h2 {
            margin: 0;
            font-size: 24px;
            line-height: 1.2;
            word-break: break-word;
        }

        .endpoint-bottom-row {
            display: grid;
            grid-template-columns: minmax(0, 1.7fr) minmax(320px, 0.9fr);
            gap: 18px;
        }

        .endpoint-description {
            margin: 0 0 16px 0;
            color: var(--muted);
            font-size: 14px;
        }

        .endpoint-status-pill {
            border-radius: 999px;
            display: inline-block;
            font-size: 12px;
            font-weight: 800;
            letter-spacing: 0.04em;
            padding: 7px 12px;
            text-transform: uppercase;
        }

        .endpoint-status-pill.status-ok {
            background: rgba(31, 143, 77, 0.12);
            border: 1px solid rgba(31, 143, 77, 0.35);
            color: var(--ok);
        }

        .endpoint-status-pill.status-warn {
            background: rgba(183, 121, 31, 0.12);
            border: 1px solid rgba(183, 121, 31, 0.35);
            color: var(--warn);
        }

        .endpoint-status-pill.status-fail {
            background: rgba(197, 48, 48, 0.12);
            border: 1px solid rgba(197, 48, 48, 0.35);
            color: var(--fail);
        }

        .endpoint-meta-stack {
            display: grid;
            gap: 10px;
        }

        .endpoint-meta-item {
            background: #f8fafc;
            border: 1px solid rgba(148, 163, 184, 0.22);
            border-radius: 10px;
            padding: 10px 12px;
            min-width: 0;
        }

        .endpoint-meta-label {
            color: var(--muted);
            display: block;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.06em;
            margin-bottom: 4px;
            text-transform: uppercase;
        }

        .endpoint-meta-item strong {
            display: block;
            font-size: 14px;
            overflow-wrap: break-word;
        }

        .endpoint-status-panel {
            background: #f8fafc;
            border: 1px solid rgba(148, 163, 184, 0.22);
            border-radius: 10px;
            padding: 14px;
            display: grid;
            align-content: center;
            gap: 14px;
        }

        .endpoint-status-heading {
            color: var(--muted);
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 0.08em;
            text-transform: uppercase;
        }

        .endpoint-count-strip {
            display: grid;
            grid-template-columns: repeat(4, minmax(0, 1fr));
            gap: 10px;
        }

        .endpoint-count {
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 10px;
            padding: 12px 8px;
            text-align: center;
        }

        .endpoint-count-number {
            display: block;
            font-size: 24px;
            font-weight: 800;
            line-height: 1;
            margin-bottom: 5px;
        }

        .endpoint-count-label {
            color: var(--muted);
            display: block;
            font-size: 11px;
            font-weight: 800;
            letter-spacing: 0.08em;
        }

        .endpoint-count-ok .endpoint-count-number {
            color: var(--ok);
        }

        .endpoint-count-warn .endpoint-count-number {
            color: var(--warn);
        }

        .endpoint-count-fail .endpoint-count-number {
            color: var(--fail);
        }

        .endpoint-count-total .endpoint-count-number {
            color: var(--text);
        }

        .summary-counts {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
        }

        .count-pill {
            background: var(--chip);
            border: 1px solid var(--border);
            border-radius: 999px;
            padding: 7px 12px;
            font-weight: 650;
            font-size: 13px;
        }

        .count-ok {
            color: var(--ok);
        }

        .count-warn {
            color: var(--warn);
        }

        .count-fail {
            color: var(--fail);
        }

        .section {
            margin-bottom: 20px;
        }

        .section-title {
            margin-bottom: 16px;
        }

        .section-title h2 {
            margin-bottom: 4px;
        }

        .section-title p {
            margin: 0;
            color: var(--muted);
            font-size: 0.95rem;
        }

        /* v0.22 Readiness Overview dashboard card styles.
           Why this exists:
           - The Readiness Overview is the fast-scan dashboard near the top of
             the static HTML report.
           - These cards summarize the five primary readiness domains and now
             act as no-JavaScript shortcuts to the matching detailed sections.
           Important:
           - This is presentation-only.
           - These classes do not change check logic, console output, TXT report
             output, or the readiness data itself.
           Troubleshooting rule:
           - Layout/visual issue: inspect these readiness-card styles first.
           - Wrong numbers/status: inspect Get-ArcForgeSectionReadiness instead.
           - Broken card jump: confirm the href="#section-name" values match the
             detailed report section IDs. */
        .readiness-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
            gap: 14px;
            align-items: stretch;
        }

        .readiness-card-link {
            color: inherit;
            text-decoration: none;
            display: flex;
            height: 100%;
        }

        .readiness-card {
            min-width: 0;
            height: 100%;
            width: 100%;
            box-sizing: border-box;
            border: 1px solid var(--border);
            border-left: 4px solid var(--muted);
            border-radius: 12px;
            padding: 16px 18px;
            background: #f8fafc;
            box-shadow: 0 2px 8px rgba(15, 23, 42, 0.04);
            transition: transform 0.15s ease, box-shadow 0.15s ease;
        }

        .readiness-card-link:hover .readiness-card {
            transform: translateY(-1px);
            box-shadow: 0 8px 18px rgba(15, 23, 42, 0.10);
        }

        .readiness-card-link:focus-visible {
            outline: 2px solid rgba(37, 99, 235, 0.35);
            outline-offset: 3px;
            border-radius: 14px;
        }

        .readiness-card-header {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 12px;
            min-height: 36px;
            margin-bottom: 12px;
        }

        .readiness-card h3 {
            margin: 0;
            min-height: 36px;
            font-size: 15px;
            line-height: 1.2;
        }

        .readiness-status {
            border-radius: 999px;
            padding: 4px 9px;
            font-size: 10px;
            font-weight: 750;
            letter-spacing: 0.05em;
            text-transform: uppercase;
            white-space: nowrap;
        }

        .readiness-counts {
            display: grid;
            grid-template-columns: repeat(3, minmax(0, 1fr));
            gap: 7px;
            margin-bottom: 11px;
        }

        .readiness-count-item {
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 10px;
            color: var(--muted);
            font-size: 11px;
            font-weight: 700;
            padding: 7px 6px;
            text-align: center;
        }

        .readiness-count-item strong {
            display: block;
            color: var(--text);
            font-family: Consolas, "Cascadia Mono", "Courier New", monospace;
            font-size: 18px;
            line-height: 1.1;
            margin-bottom: 2px;
        }

        .readiness-count-item span {
            display: block;
        }

        .readiness-count-ok strong {
            color: var(--ok);
        }

        .readiness-count-warn strong {
            color: var(--warn);
        }

        .readiness-count-fail strong {
            color: var(--fail);
        }

        .readiness-card-summary {
            margin: 0;
            color: var(--muted);
            font-size: 12.5px;
            line-height: 1.45;
        }

        .readiness-card-ok {
            border-left-color: var(--ok);
        }

        .readiness-card-ok .readiness-status {
            background: rgba(31, 143, 77, 0.12);
            color: var(--ok);
        }

        .readiness-card-warn {
            border-left-color: var(--warn);
        }

        .readiness-card-warn .readiness-status {
            background: rgba(183, 121, 31, 0.12);
            color: var(--warn);
        }

        .readiness-card-fail {
            border-left-color: var(--fail);
        }

        .readiness-card-fail .readiness-status {
            background: rgba(197, 48, 48, 0.12);
            color: var(--fail);
        }

        .readiness-card-unknown {
            border-left-color: var(--muted);
        }

        .readiness-card-unknown .readiness-status {
            background: rgba(101, 117, 139, 0.12);
            color: var(--muted);
        }

        /* v0.17/v0.23 Recommended Actions queue styles.
           These classes only affect the HTML report. They do not affect console
           output, TXT reports, or the health-check logic.

           v0.23 note:
           - The queue is now severity-first so FAIL actions appear above WARN actions.
           - Category context still appears inside each card as a small metadata line. */

        /* Compact summary strip shown above the action queue. */
        .action-summary-strip {
            display: flex;
            flex-wrap: wrap;
            gap: 8px;
            margin: 14px 0 18px 0;
        }

        /* Small count pills for total actions, FAIL actions, and WARN actions. */
        .action-summary-chip {
            display: inline-flex;
            align-items: center;
            gap: 5px;
            background: var(--chip);
            border: 1px solid var(--border);
            border-radius: 999px;
            color: var(--muted);
            font-size: 12px;
            padding: 7px 10px;
        }

        .action-summary-chip strong {
            color: #0f172a;
        }

        .action-summary-fail strong {
            color: var(--fail);
        }

        .action-summary-warn strong {
            color: var(--warn);
        }

        /* Overall container for all action groups. Grid gives us even spacing
           between groups without needing JavaScript or external CSS. */
        .action-queue {
            display: grid;
            gap: 16px;
        }

        /* One severity group box, such as Failed Actions or Warnings. */
        .action-group {
            border: 1px solid var(--border);
            border-radius: 14px;
            background: #f8fafc;
            padding: 16px;
        }

        /* Header row for each severity group. */
        .action-group-header {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 14px;
            margin-bottom: 12px;
        }

        /* Severity group heading. */
        .action-group h3 {
            margin: 0;
            font-size: 15px;
        }

        /* Short explanation under each severity group heading. */
        .action-group-header p {
            margin: 5px 0 0 0;
            color: var(--muted);
            font-size: 12px;
        }

        /* Small count pill shown in each severity group header. */
        .action-group-count {
            flex: 0 0 auto;
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 999px;
            color: var(--muted);
            font-size: 12px;
            padding: 5px 10px;
        }

        /* One individual ticket-style action item. The left border is neutral by
           default and becomes yellow/red when action-warn or action-fail is added. */
        .action-item {
            background: var(--panel);
            border: 1px solid var(--border);
            border-left: 5px solid var(--muted);
            border-radius: 12px;
            padding: 13px 14px;
            margin-top: 10px;
        }

        /* WARN action items get the warning color on the left border. */
        .action-warn {
            border-left-color: var(--warn);
        }

        /* FAIL action items get the failure color on the left border. */
        .action-fail {
            border-left-color: var(--fail);
        }

        /* Header row inside an action item. Flex keeps the severity badge and
           title aligned while still allowing wrapping on smaller screens. */
        .action-header {
            display: flex;
            align-items: center;
            gap: 10px;
            flex-wrap: wrap;
        }

        /* Small WARN/FAIL pill shown beside each action title. */
        .action-severity {
            background: var(--chip);
            border: 1px solid var(--border);
            border-radius: 999px;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.04em;
            padding: 4px 9px;
        }

        /* Make the WARN badge text use the same warning color used elsewhere. */
        .action-warn .action-severity {
            color: var(--warn);
        }

        /* Make the FAIL badge text use the same failure color used elsewhere. */
        .action-fail .action-severity {
            color: var(--fail);
        }

        /* Small category metadata line inside each action card. */
        .action-meta {
            color: var(--muted);
            font-size: 12px;
            margin-top: 8px;
        }

        /* Optional detail text under each action item. */
        .action-detail {
            margin: 8px 0 0 0;
            color: var(--muted);
            font-size: 13px;
        }

        /* Suggested action block under each action item. */
        .action-suggestion {
            margin-top: 10px;
        }

        .action-suggestion p {
            margin: 4px 0 0 0;
            color: var(--muted);
            font-size: 13px;
        }

        /* Small label that separates the action instruction from the finding title. */
        .action-label {
            color: #0f172a;
            display: block;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.06em;
            text-transform: uppercase;
        }

        ul {
            margin: 0;
            padding-left: 22px;
        }

        li {
            margin: 8px 0;
        }

        code {
            background: #f1f5f9;
            border: 1px solid #e2e8f0;
            border-radius: 6px;
            padding: 2px 5px;
            font-family: Consolas, "Courier New", monospace;
            font-size: 13px;
        }

        pre {
            white-space: pre-wrap;
            word-break: break-word;
            background: #0f172a;
            color: #e5e7eb;
            border-radius: 12px;
            padding: 18px;
            overflow-x: auto;
            font-family: Consolas, "Courier New", monospace;
            font-size: 13px;
        }

        /* v0.21 collapsible technical depth
        Why this exists:
        - Raw Findings are useful for troubleshooting, but visually heavy.
        - Native <details>/<summary> gives us a clean collapse/expand control.
        - This uses no JavaScript and does not affect check logic, console output, or TXT output.

        Troubleshooting rule:
        - Treat <summary> like the clickable button.
        - Treat summary::after like the chevron icon.
        */
        /* v0.24 System evidence dashboard.
           Why this exists:
           - The System section now mirrors common triage/reporting patterns by
             grouping endpoint identity, vital signs, storage, process health,
             and core service trust into separate static evidence panels.
           - These styles are scoped to system-* classes so this release does not
             redesign Network, Software Readiness, Security, Updates, Raw
             Findings, or other previously shipped report modules.

           Important:
           - HTML/CSS only. No JavaScript.
           - Presentation-only. No new checks, scoring changes, console changes,
             or TXT report changes. */
        .system-collapsible-stack {
            display: grid;
            gap: 14px;
        }

        .system-collapsible-card {
            background: #ffffff;
            border: 1px solid var(--border);
            border-radius: 14px;
            box-shadow: 0 2px 8px rgba(15, 23, 42, 0.05);
            min-width: 0;
            overflow: hidden;
            scroll-margin-top: 24px;
        }

        .system-collapsible-summary {
            align-items: center;
            color: #0f172a;
            cursor: pointer;
            display: flex;
            font-size: 15px;
            font-weight: 850;
            gap: 16px;
            justify-content: space-between;
            list-style: none;
            min-height: 58px;
            padding: 0 1cm;
            user-select: none;
        }

        .system-collapsible-summary::-webkit-details-marker {
            display: none;
        }

        .system-collapsible-summary::marker {
            content: "";
        }

        .system-collapsible-card[open] > .system-collapsible-summary {
            border-bottom: 1px solid rgba(148, 163, 184, 0.28);
        }

        .system-collapsible-chevron {
            align-items: center;
            color: #64748b;
            display: inline-flex;
            flex: 0 0 18px;
            font-size: 0;
            height: 18px;
            justify-content: center;
            line-height: 0;
            position: relative;
            width: 18px;
        }

        .system-collapsible-chevron::before {
            border-bottom: 2px solid currentColor;
            border-right: 2px solid currentColor;
            content: "";
            display: block;
            height: 7px;
            transform: rotate(-45deg);
            transform-origin: center;
            transition: transform 0.2s ease;
            width: 7px;
        }

        .system-collapsible-card[open] > .system-collapsible-summary .system-collapsible-chevron::before {
            transform: rotate(45deg);
        }

        .system-collapsible-card-body {
            display: grid;
            gap: 14px;
            padding: 14px;
        }

        .system-collapsible-description {
            color: var(--muted);
            font-size: 13px;
            margin: 0;
        }

        .system-evidence-grid {
            display: grid;
            grid-template-columns: repeat(2, minmax(0, 1fr));
            gap: 14px;
        }

        .system-evidence-panel,
        .system-detail-card {
            border: 1px solid var(--border);
            border-radius: 14px;
            background: #fbfdff;
            padding: 14px;
            min-width: 0;
        }

        .system-evidence-panel {
            display: flex;
            flex-direction: column;
        }

        .system-panel-wide {
            grid-column: 1 / -1;
        }

        .system-panel-header {
            margin-bottom: 12px;
        }

        .system-panel-header h3 {
            margin: 0 0 4px 0;
            font-size: 15px;
        }

        .system-panel-header p {
            margin: 0;
            color: var(--muted);
            font-size: 13px;
        }

        .system-evidence-rows {
            display: grid;
            gap: 8px;
        }

        .system-evidence-row {
            display: grid;
            grid-template-columns: auto minmax(120px, 0.6fr) minmax(0, 1.4fr);
            gap: 10px;
            align-items: center;
            border-top: 1px solid rgba(148, 163, 184, 0.22);
            padding-top: 8px;
            min-width: 0;
        }

        .system-status-label-row {
            display: grid;
            grid-template-columns: auto minmax(0, 1fr);
            gap: 10px;
            align-items: center;
            border-top: 1px solid rgba(148, 163, 184, 0.22);
            padding-top: 8px;
            min-width: 0;
        }

        .system-status-label-row:first-child {
            border-top: 0;
            padding-top: 0;
        }

        .system-evidence-row:first-child {
            border-top: 0;
            padding-top: 0;
        }

        .system-evidence-row-informational {
            grid-template-columns: minmax(160px, 0.55fr) minmax(0, 1.45fr);
        }

        .system-status-pill {
            border-radius: 999px;
            display: inline-block;
            font-size: 11px;
            font-weight: 800;
            letter-spacing: 0.04em;
            min-width: 58px;
            padding: 4px 8px;
            text-align: center;
        }

        .system-status-ok {
            background: rgba(31, 143, 77, 0.11);
            border: 1px solid rgba(31, 143, 77, 0.28);
            color: var(--ok);
        }

        .system-status-warn {
            background: rgba(183, 121, 31, 0.11);
            border: 1px solid rgba(183, 121, 31, 0.28);
            color: var(--warn);
        }

        .system-status-fail {
            background: rgba(197, 48, 48, 0.11);
            border: 1px solid rgba(197, 48, 48, 0.28);
            color: var(--fail);
        }

        .system-status-unknown {
            background: var(--chip);
            border: 1px solid var(--border);
            color: var(--muted);
        }

        .system-evidence-label {
            color: var(--muted);
            font-size: 13px;
            font-weight: 700;
        }

        .system-evidence-value {
            font-size: 13px;
            font-weight: 650;
            min-width: 0;
            overflow-wrap: anywhere;
        }

        .system-evidence-value-missing {
            color: var(--muted);
            font-style: italic;
            font-weight: 650;
        }

        .system-storage-widget {
            display: grid;
            gap: 10px;
        }

        .system-storage-drive-row {
            align-items: baseline;
            display: flex;
            gap: 12px;
            justify-content: space-between;
        }

        .system-storage-drive-name {
            color: #0f172a;
            font-size: 13px;
            font-weight: 850;
        }

        .system-storage-used-summary {
            color: #0f172a;
            font-size: 12px;
            font-weight: 750;
            text-align: right;
        }

        .system-storage-meter-block {
            display: grid;
            gap: 6px;
        }

        .system-storage-meter,
        .system-storage-meter-empty {
            background: #dbe2ea;
            border-radius: 999px;
            height: 12px;
            overflow: hidden;
            width: 100%;
        }

        .system-storage-meter-fill {
            border-radius: 999px 0 0 999px;
            height: 100%;
        }

        .system-storage-percent-row,
        .system-storage-free-row {
            color: #475569;
            font-size: 12px;
            font-weight: 750;
        }

        .system-storage-legend-row {
            align-items: center;
            color: #475569;
            display: flex;
            flex-wrap: wrap;
            gap: 16px;
            font-size: 12px;
            font-weight: 800;
        }

        .system-storage-legend-item {
            align-items: center;
            display: inline-flex;
            gap: 6px;
            white-space: nowrap;
        }

        .system-storage-legend-marker {
            border-radius: 2px;
            display: inline-block;
            height: 8px;
            width: 8px;
        }

        .system-storage-legend-free {
            background: #dbe2ea;
        }

        .system-meter-ok {
            background: var(--ok);
        }

        .system-meter-warn {
            background: var(--warn);
        }

        .system-meter-fail {
            background: var(--fail);
        }

        .system-meter-unknown {
            background: var(--muted);
        }

        .system-panel-footer {
            margin-top: auto;
            padding-top: 12px;
        }

        .system-panel-link {
            align-items: center;
            border-top: 1px solid rgba(148, 163, 184, 0.22);
            color: #0f172a;
            display: flex;
            font-size: 13px;
            font-weight: 800;
            justify-content: space-between;
            line-height: 1;
            min-height: 48px;
            text-decoration: none;
        }

        .system-panel-link-text {
            align-items: center;
            display: inline-flex;
            line-height: 1;
            transform: translateY(3px);
        }

        .system-panel-link::after {
            align-items: center;
            color: #0f172a;
            content: "›";
            display: inline-flex;
            font-size: 30px;
            font-weight: 500;
            height: 24px;
            justify-content: center;
            line-height: 1;
            margin-left: 16px;
            transform: translateY(-1px);
            width: 24px;
        }

        .system-panel-link:hover {
            text-decoration: none;
        }

        .system-process-snapshot-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
            gap: 14px;
        }

        .system-process-snapshot-card {
            border: 1px solid rgba(148, 163, 184, 0.26);
            border-radius: 12px;
            padding: 12px;
            min-width: 0;
        }

        .system-compact-list {
            margin: 8px 0 0 0;
            padding-left: 20px;
            color: #0f172a;
            font-size: 13px;
            font-weight: 650;
        }

        .system-compact-list-separated {
            border-top: 1px solid rgba(148, 163, 184, 0.22);
            margin-top: 0;
            padding-top: 7px;
        }

        .system-compact-list li + li {
            margin-top: 4px;
        }

        .system-mini-table-title {
            color: var(--muted);
            font-size: 13px;
            font-weight: 800;
            margin-bottom: 8px;
        }

        .system-mini-table {
            border-collapse: collapse;
            font-size: 13px;
            width: 100%;
        }

        .system-mini-table th,
        .system-mini-table td {
            border-top: 1px solid rgba(148, 163, 184, 0.22);
            padding: 7px 6px;
            text-align: left;
            vertical-align: top;
        }

        .system-mini-table th {
            color: var(--muted);
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }

        .system-mini-table td:first-child,
        .system-mini-table th:first-child {
            width: 42px;
        }

        .system-service-matrix {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 10px;
        }

        .system-service-cell {
            border: 1px solid var(--border);
            border-radius: 12px;
            display: grid;
            gap: 5px;
            padding: 10px;
            min-width: 0;
        }

        .system-service-name {
            font-size: 13px;
            font-weight: 800;
        }

        .system-service-status {
            border-radius: 999px;
            display: inline-block;
            font-size: 11px;
            font-weight: 800;
            justify-self: start;
            letter-spacing: 0.04em;
            padding: 4px 8px;
        }

        .system-service-detail {
            color: var(--muted);
            font-size: 12px;
            overflow-wrap: anywhere;
        }

        .system-service-ok {
            background: rgba(31, 143, 77, 0.06);
            border-color: rgba(31, 143, 77, 0.24);
        }

        .system-service-ok .system-service-status {
            background: rgba(31, 143, 77, 0.12);
            color: var(--ok);
        }

        .system-service-warn {
            background: rgba(183, 121, 31, 0.06);
            border-color: rgba(183, 121, 31, 0.24);
        }

        .system-service-warn .system-service-status {
            background: rgba(183, 121, 31, 0.12);
            color: var(--warn);
        }

        .system-service-fail {
            background: rgba(197, 48, 48, 0.06);
            border-color: rgba(197, 48, 48, 0.24);
        }

        .system-service-fail .system-service-status {
            background: rgba(197, 48, 48, 0.12);
            color: var(--fail);
        }

        .system-service-unknown .system-service-status {
            background: var(--chip);
            color: var(--muted);
        }

        .system-detail-sections {
            display: grid;
            gap: 14px;
            margin-top: 14px;
        }

        .system-detail-card {
            scroll-margin-top: 24px;
        }

        .system-detail-empty {
            font-size: 13px;
            font-weight: 650;
        }

        .technical-depth {
            margin: 0;
        }

        .technical-depth summary {
            min-height: 48px;
            padding: 0 24px;
            cursor: pointer;
            list-style: none;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 16px;
            font-size: 1.05rem;
            font-weight: 700;
            color: #0f172a;
            user-select: none;
        }

        .technical-depth summary::-webkit-details-marker {
            display: none;
        }

        .technical-depth summary::marker {
            content: "";
        }

        /* Custom chevron.
        This avoids the "door off the hinges" look because the icon is a small CSS shape
        rotating around its own center instead of rotating a text glyph.
        */
        .technical-depth summary::after {
            content: "";
            width: 9px;
            height: 9px;
            border-right: 2px solid #64748b;
            border-bottom: 2px solid #64748b;
            transform: rotate(-45deg);
            transform-origin: center center;
            transition: transform 0.2s ease;
            flex: 0 0 auto;
        }

        /* When the native details block is open, rotate the chevron downward. */
        .technical-depth[open] summary::after {
            transform: rotate(45deg);
        }

        .technical-depth[open] summary {
            border-bottom: 1px solid #e2e8f0;
        }

        .technical-depth pre {
            margin: 20px;
        }

        .muted {
            color: var(--muted);
        }

        @media (max-width: 900px) {
            .report-shell {
                grid-template-columns: 1fr;
            }

            .report-sidebar {
                position: static;
            }

            .endpoint-main,
            .endpoint-bottom-row {
                grid-template-columns: 1fr;
            }

            .grid {
                grid-template-columns: repeat(2, minmax(0, 1fr));
            }

            .system-service-matrix {
                grid-template-columns: repeat(2, minmax(0, 1fr));
            }
        }

        @media (max-width: 600px) {
            body {
                padding: 16px;
            }

            .grid,
            .endpoint-count-strip,
            .system-evidence-grid,
            .system-service-matrix,
            .system-process-snapshot-grid {
                grid-template-columns: 1fr;
            }

            .system-evidence-row {
                grid-template-columns: 1fr;
                gap: 4px;
            }

            .system-status-label-row {
                grid-template-columns: 1fr;
                gap: 4px;
            }
        }
    </style>
</head>
<body>
    <div class="report-shell">
$ReportNavigationHtml

        <main class="report-main">
        <!-- ============================================================
             v0.18 REPORT SUMMARY MODULE
             ============================================================
             This named section groups the top summary area of the HTML report.

             Sidebar link:
             - href="#report-summary"

             Matching anchor:
             - id="report-summary"

             Why this matters:
             - The sidebar can now jump back to the top summary area without using
               a generic "Back to Top" label.
             - This keeps the HTML report modular: Report Summary, Incident Summary,
               Readiness Overview, detailed sections, Recommended Actions, and Raw Findings.

             Contains:
             - report title/status header
             - v0.20 Endpoint Summary badge
             - report ID
             - generated time
             - computer name
             - current user
             - Battlestation Profile
             - overall status
             - OK/WARN/FAIL/total check counts
             ============================================================ -->
        <section id="report-summary" class="report-summary">
        <header class="ticket-header">
            <div class="eyebrow">ArcForge First Response</div>
            <h1>First Response Report</h1>
            <div class="subtitle">Static triage record generated from local workstation readiness checks.</div>
        </header>

$EndpointSummaryHtml
        </section>
        <!-- v0.18 REPORT SUMMARY MODULE END -->

        <section id="incident-summary" class="card section">
            <h2>Incident Summary</h2>
            <p class="muted">
                ArcForge First Response completed a local workstation readiness check using the
                <strong>$(ConvertTo-HtmlSafeText $BattlestationProfile)</strong> Battlestation Profile.
            </p>
            <div class="summary-counts">
                <span class="count-pill count-ok">OK: $OkCount</span>
                <span class="count-pill count-warn">WARN: $WarnCount</span>
                <span class="count-pill count-fail">FAIL: $FailCount</span>
            </div>
        </section>

$ReadinessOverviewHtml

$SystemEvidenceHtml

        <section id="network" class="card section">
            <h2>Network</h2>
            <ul>
                $NetworkFindingsHtml
            </ul>
        </section>

        <section id="software-readiness" class="card section">
            <h2>Software Readiness</h2>
            <ul>
                $SoftwareFindingsHtml
            </ul>
        </section>

        <section id="security" class="card section">
            <h2>Security</h2>
            <ul>
                $SecurityFindingsHtml
            </ul>
        </section>

        <section id="updates" class="card section">
            <h2>Updates</h2>
            <ul>
                $UpdatesFindingsHtml
            </ul>
        </section>

$RecommendedActionsHtml

        <!--
            v0.21 collapsible technical depth
            Why this exists:
            - Raw Findings are still part of the HTML report, but they are no
              longer forced into the main scan path.
            - <details>/<summary> is native HTML, so this adds collapsible
              behavior without JavaScript or external dependencies.

            Important:
            - This is presentation-only.
            - This does not change check logic, console output, or TXT output.
            - The sidebar link still points to this same raw-findings section.
        -->
        <section id="raw-findings" class="card section">
            <details class="technical-depth">
                <summary>Raw Findings</summary>
                <pre>$RawFindings</pre>
            </details>
        </section>
        </main>
    </div>
</body>
</html>
"@

    $Html | Out-File -FilePath $OutputPath -Encoding UTF8
}

Write-Host "=========================" -ForegroundColor Gray
Write-Host " ArcForge First Response" -ForegroundColor Gray
Write-Host "=========================" -ForegroundColor Gray
Write-Host ""

Add-ReportLine -Line "========================="
Add-ReportLine -Line " ArcForge First Response"
Add-ReportLine -Line "========================="
Add-ReportLine

Write-Result -Status "OK" -Label "Computer Name:" -Value $ComputerName
Write-Result -Status "OK" -Label "Current User:" -Value $CurrentUser
Write-Result -Status "OK" -Label "Report Date:" -Value $ReportDate
Write-Result -Status "OK" -Label "Active Profile:" -Value $BattlestationProfile

# System Checks
Write-Section -Title "SYSTEM"

try {
    $OS = Get-CimInstance Win32_OperatingSystem

    Write-Result -Status "OK" -Label "OS Name:" -Value $OS.Caption
    Write-Result -Status "OK" -Label "OS Version:" -Value $OS.Version
    Write-Result -Status "OK" -Label "Architecture:" -Value $OS.OSArchitecture
}
catch {
    Write-Result -Status "FAIL" -Label "System Info:" -Value $_.Exception.Message
}

# Uptime Check
Write-Section -Title "UPTIME"

try {
    $LastBoot = $OS.LastBootUpTime
    $Uptime = (Get-Date) - $LastBoot
    $UptimeDays = [math]::Round($Uptime.TotalDays, 2)

    Write-Result -Status "OK" -Label "Last Boot:" -Value $LastBoot

    if ($UptimeDays -ge 14) {
        Write-Result -Status "WARN" -Label "Uptime Days:" -Value "$UptimeDays days - reboot recommended"
    }
    else {
        Write-Result -Status "OK" -Label "Uptime Days:" -Value "$UptimeDays days"
    }
}
catch {
    Write-Result -Status "FAIL" -Label "Uptime:" -Value $_.Exception.Message
}

# Process Readiness Checks
Write-Section -Title "PROCESSES"

try {
    $HungProcesses = Get-Process -ErrorAction Stop |
        Where-Object {
            $_.MainWindowTitle -and
            $_.Responding -eq $false
        }

    if ($HungProcesses.Count -gt 0) {
        $HungNames = ($HungProcesses.ProcessName | Sort-Object -Unique) -join ", "
        Write-Result -Status "WARN" -Label "Hung Apps:" -Value "$($HungProcesses.Count) non-responding app(s): $HungNames"
    }
    else {
        Write-Result -Status "OK" -Label "Hung Apps:" -Value "None detected"
    }
}
catch {
    Write-Result -Status "WARN" -Label "Hung Apps:" -Value "Unable to query process responsiveness"
}

try {
    $TopMemoryProcesses = Get-Process -ErrorAction Stop |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 5

    foreach ($Process in $TopMemoryProcesses) {
        $MemoryMB = [math]::Round($Process.WorkingSet64 / 1MB, 2)
        Write-Result -Status "OK" -Label "Top Memory:" -Value "$($Process.ProcessName) - $MemoryMB MB" -CountResult:$false
    }
}
catch {
    Write-Result -Status "WARN" -Label "Memory Usage:" -Value "Unable to query top memory processes"
}

# Service Readiness Checks
Write-Section -Title "SERVICES"

# Core workstation services only.
# Antivirus/security provider service validation will be handled separately later
# so third-party AV products do not trigger false Defender warnings.
$CoreServices = @(
    @{
        Name = "EventLog"
        Label = "Event Log:"
    },
    @{
        Name = "Winmgmt"
        Label = "WMI:"
    },
    @{
        Name = "LanmanWorkstation"
        Label = "Workstation:"
    },
    @{
        Name = "Dnscache"
        Label = "DNS Client:"
    }
)

foreach ($Service in $CoreServices) {
    try {
        $ServiceInfo = Get-CimInstance Win32_Service -Filter "Name='$($Service.Name)'" -ErrorAction Stop

        if (-not $ServiceInfo) {
            Write-Result -Status "WARN" -Label $Service.Label -Value "Service not found"
        }
        elseif ($ServiceInfo.StartMode -eq "Disabled") {
            Write-Result -Status "WARN" -Label $Service.Label -Value "Disabled"
        }
        elseif ($ServiceInfo.State -eq "Running") {
            Write-Result -Status "OK" -Label $Service.Label -Value "$($ServiceInfo.StartMode) / Running"
        }
        else {
            Write-Result -Status "WARN" -Label $Service.Label -Value "$($ServiceInfo.StartMode) / $($ServiceInfo.State)"
        }
    }
    catch {
        Write-Result -Status "WARN" -Label $Service.Label -Value "Unable to query service"
    }
}

# Storage Check
Write-Section -Title "STORAGE"

try {
    $Disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $FreeGB = [math]::Round($Disk.FreeSpace / 1GB, 2)
    $TotalGB = [math]::Round($Disk.Size / 1GB, 2)
    $FreePercent = [math]::Round(($Disk.FreeSpace / $Disk.Size) * 100, 2)

    Write-Result -Status "OK" -Label "Drive:" -Value "C:"
    Write-Result -Status "OK" -Label "Total Size:" -Value "$TotalGB GB"

    if ($FreePercent -lt 10) {
        Write-Result -Status "FAIL" -Label "Free Space:" -Value "$FreeGB GB free ($FreePercent%) - critically low"
    }
    elseif ($FreePercent -lt 20) {
        Write-Result -Status "WARN" -Label "Free Space:" -Value "$FreeGB GB free ($FreePercent%) - low disk space"
    }
    else {
        Write-Result -Status "OK" -Label "Free Space:" -Value "$FreeGB GB free ($FreePercent%)"
    }
}
catch {
    Write-Result -Status "FAIL" -Label "Storage:" -Value $_.Exception.Message
}

# Network Checks
Write-Section -Title "NETWORK"

try {
    $NetworkConfig = Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object {
            $_.IPEnabled -eq $true -and
            $_.DefaultIPGateway -ne $null
        } |
        Select-Object -First 1

    if ($NetworkConfig) {
        $Gateway = $NetworkConfig.DefaultIPGateway[0]
        $IPAddress = $NetworkConfig.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
        $DNSServers = $NetworkConfig.DNSServerSearchOrder -join ", "

        Write-Result -Status "OK" -Label "IPv4 Address:" -Value $IPAddress
        Write-Result -Status "OK" -Label "Gateway:" -Value $Gateway
        Write-Result -Status "OK" -Label "DNS Servers:" -Value $DNSServers

        if (Test-Connection -ComputerName $Gateway -Count 2 -Quiet) {
            Write-Result -Status "OK" -Label "Gateway Ping:" -Value "Reachable"
        }
        else {
            Write-Result -Status "FAIL" -Label "Gateway Ping:" -Value "Unreachable"
        }
    }
    else {
        Write-Result -Status "FAIL" -Label "Network Config:" -Value "No active adapter with default gateway found"
    }
}
catch {
    Write-Result -Status "FAIL" -Label "Network Config:" -Value $_.Exception.Message
}

if (Test-Connection -ComputerName "1.1.1.1" -Count 2 -Quiet) {
    Write-Result -Status "OK" -Label "Internet Ping:" -Value "1.1.1.1 reachable"
}
else {
    Write-Result -Status "FAIL" -Label "Internet Ping:" -Value "1.1.1.1 unreachable"
}

try {
    Resolve-DnsName "github.com" -ErrorAction Stop | Out-Null
    Write-Result -Status "OK" -Label "DNS Resolution:" -Value "github.com resolved"
}
catch {
    Write-Result -Status "FAIL" -Label "DNS Resolution:" -Value "Failed to resolve github.com"
}

# Software Checks
Write-Section -Title "SOFTWARE"

$CatalogFolder = Join-Path $ProjectRoot "catalog"
$CatalogFile = Join-Path $CatalogFolder "arcforge-software-catalog.csv"

if ($BattlestationProfile -eq "General") {
    Write-Result -Status "OK" -Label "Profile Tools:" -Value "No profile-specific software checks for General profile" -CountResult:$false
}
elseif (-not (Test-Path $CatalogFile)) {
    Write-Result -Status "WARN" -Label "Catalog File:" -Value "Not found at $CatalogFile"
    Write-Result -Status "WARN" -Label "Profile Tools:" -Value "Unable to run catalog-based software checks for $BattlestationProfile"
}
else {
    try {
        $SoftwareCatalog = Import-Csv -Path $CatalogFile

        $SelectedSoftwareTools = @(
            $SoftwareCatalog | Where-Object {
                (Test-YesValue (Get-CatalogValue -Row $_ -ColumnName $BattlestationProfile)) -and
                ((Get-CatalogValue -Row $_ -ColumnName "Priority") -eq "Recommended")
            }
        )

        if (-not $SelectedSoftwareTools -or $SelectedSoftwareTools.Count -eq 0) {
            Write-Result -Status "OK" -Label "Profile Tools:" -Value "No recommended software checks for $BattlestationProfile profile" -CountResult:$false
        }
        else {
            Write-Result -Status "OK" -Label "Profile Tools:" -Value "$($SelectedSoftwareTools.Count) recommended software check(s) selected for $BattlestationProfile" -CountResult:$false

            $SoftwareCategories = @(
                $SelectedSoftwareTools |
                    Select-Object -ExpandProperty Category -Unique |
                    Sort-Object
            )

            foreach ($Category in $SoftwareCategories) {
                $CategoryTools = @($SelectedSoftwareTools | Where-Object { $_.Category -eq $Category })

                if (-not $CategoryTools -or $CategoryTools.Count -eq 0) {
                    continue
                }

                Add-ReportLine
                Add-ReportLine -Line "[$Category]"
                Write-Host ""
                Write-Host "[$Category]" -ForegroundColor Gray

                foreach ($Tool in $CategoryTools) {
                    $ToolName = Get-CatalogValue -Row $Tool -ColumnName "Software Name"
                    $DetectionConfig = Get-SoftwareDetectionConfig -CatalogRow $Tool

                    $Installed = Test-SoftwareInstalled `
                        -SoftwareName $Tool."Software Name" `
                        -Commands $DetectionConfig.Commands `
                        -DisplayNamePatterns $DetectionConfig.DisplayNamePatterns `
                        -CommonPaths $DetectionConfig.CommonPaths `
                        -Services $DetectionConfig.Services

                    if ($Installed) {
                        Write-Result -Status "OK" -Label "$($ToolName):" -Value "Installed"
                    }
                    else {
                        Write-Result -Status "WARN" -Label "$($ToolName):" -Value "Recommended for $BattlestationProfile profile but not found"
                    }
                }
            }
        }
    }
    catch {
        Write-Result -Status "WARN" -Label "Catalog File:" -Value "Unable to read $CatalogFile"
        Write-Result -Status "WARN" -Label "Catalog Error:" -Value $_.Exception.Message
    }
}

# Security Checks
Write-Section -Title "SECURITY"

try {
    $FirewallProfiles = Get-NetFirewallProfile -ErrorAction Stop
    $DisabledProfiles = $FirewallProfiles | Where-Object { $_.Enabled -eq $false }

    if ($DisabledProfiles.Count -eq 0) {
        Write-Result -Status "OK" -Label "Firewall:" -Value "Enabled for all profiles"
    }
    else {
        $DisabledNames = ($DisabledProfiles.Name -join ", ")
        Write-Result -Status "WARN" -Label "Firewall:" -Value "Disabled profile(s): $DisabledNames"
    }
}
catch {
    try {
        $FirewallState = netsh advfirewall show allprofiles state

        if ($FirewallState -match "State\s+OFF") {
            Write-Result -Status "WARN" -Label "Firewall:" -Value "One or more profiles may be disabled"
        }
        elseif ($FirewallState -match "State\s+ON") {
            Write-Result -Status "OK" -Label "Firewall:" -Value "Enabled - verified with netsh"
        }
        else {
            Write-Result -Status "WARN" -Label "Firewall:" -Value "Unable to determine firewall state"
        }
    }
    catch {
        Write-Result -Status "WARN" -Label "Firewall:" -Value "Unable to query firewall status"
    }
}

try {
    $AntivirusProducts = Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction Stop

    if ($AntivirusProducts) {
        $AntivirusNames = ($AntivirusProducts.displayName | Sort-Object -Unique) -join ", "
        Write-Result -Status "OK" -Label "Antivirus:" -Value "$AntivirusNames registered"
    }
    else {
        Write-Result -Status "WARN" -Label "Antivirus:" -Value "No registered antivirus provider found"
    }
}
catch {
    Write-Result -Status "WARN" -Label "Antivirus:" -Value "Unable to query antivirus provider"
}

try {
    $LocalAdmins = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop
    $AdminCount = $LocalAdmins.Count

    if ($AdminCount -le 1) {
        Write-Result -Status "OK" -Label "Local Admins:" -Value "$AdminCount member"
    }
    else {
        Write-Result -Status "WARN" -Label "Local Admins:" -Value "$AdminCount members - review recommended"
    }
}
catch {
    Write-Result -Status "WARN" -Label "Local Admins:" -Value "Unable to query local administrators"
}

# Windows Update Checks
Write-Section -Title "UPDATES"

try {
    $WindowsUpdateService = Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -ErrorAction Stop

    if ($WindowsUpdateService.StartMode -eq "Disabled") {
        Write-Result -Status "WARN" -Label "Update Service:" -Value "Disabled"
    }
    elseif ($WindowsUpdateService.State -eq "Running") {
        Write-Result -Status "OK" -Label "Update Service:" -Value "$($WindowsUpdateService.StartMode) / Running"
    }
    else {
        Write-Result -Status "OK" -Label "Update Service:" -Value "$($WindowsUpdateService.StartMode) / $($WindowsUpdateService.State) - available on demand"
    }
}
catch {
    Write-Result -Status "WARN" -Label "Update Service:" -Value "Unable to query Windows Update service"
}

try {
    $BitsService = Get-CimInstance Win32_Service -Filter "Name='BITS'" -ErrorAction Stop

    if ($BitsService.StartMode -eq "Disabled") {
        Write-Result -Status "WARN" -Label "BITS Service:" -Value "Disabled"
    }
    elseif ($BitsService.State -eq "Running") {
        Write-Result -Status "OK" -Label "BITS Service:" -Value "$($BitsService.StartMode) / Running"
    }
    else {
        Write-Result -Status "OK" -Label "BITS Service:" -Value "$($BitsService.StartMode) / $($BitsService.State) - available on demand"
    }
}
catch {
    Write-Result -Status "WARN" -Label "BITS Service:" -Value "Unable to query BITS service"
}

try {
    $PendingRebootPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    )

    $PendingReboot = $false

    foreach ($Path in $PendingRebootPaths) {
        if ($Path -eq "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager") {
            $PendingFileRename = Get-ItemProperty -Path $Path -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue

            if ($PendingFileRename) {
                $PendingReboot = $true
            }
        }
        elseif (Test-Path $Path) {
            $PendingReboot = $true
        }
    }

    if ($PendingReboot) {
        Write-Result -Status "WARN" -Label "Pending Reboot:" -Value "Detected - reboot recommended"
    }
    else {
        Write-Result -Status "OK" -Label "Pending Reboot:" -Value "Not detected"
    }
}
catch {
    Write-Result -Status "WARN" -Label "Pending Reboot:" -Value "Unable to determine reboot status"
}

try {
    $LatestHotFix = Get-HotFix |
        Sort-Object InstalledOn -Descending |
        Select-Object -First 1

    if ($LatestHotFix) {
        Write-Result -Status "OK" -Label "Last Hotfix:" -Value "$($LatestHotFix.HotFixID) installed on $($LatestHotFix.InstalledOn.ToShortDateString())"
    }
    else {
        Write-Result -Status "WARN" -Label "Last Hotfix:" -Value "No hotfix history found"
    }
}
catch {
    Write-Result -Status "WARN" -Label "Last Hotfix:" -Value "Unable to query hotfix history"
}

Write-Summary

Write-Host ""
Write-Host "Health check complete." -ForegroundColor Gray
Write-Host "TXT report saved to: $ReportFile" -ForegroundColor Gray
Write-Host "HTML report saved to: $HtmlReportFile" -ForegroundColor Gray

Add-ReportLine
Add-ReportLine -Line "Health check complete."
Add-ReportLine -Line "TXT report saved to: $ReportFile"
Add-ReportLine -Line "HTML report saved to: $HtmlReportFile"

$ReportLines | Out-File -FilePath $ReportFile -Encoding UTF8

New-ArcForgeHtmlReport `
    -OutputPath $HtmlReportFile `
    -ReportId $ReportId `
    -ComputerName $ComputerName `
    -CurrentUser $CurrentUser `
    -BattlestationProfile $BattlestationProfile `
    -GeneratedAt $ReportDate `
    -CheckCounts $CheckCounts `
    -ReportLines $ReportLines