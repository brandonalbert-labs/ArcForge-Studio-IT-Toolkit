# ArcForge First Response
# Console/TXT report helper module
#
# This file contains the shared helpers that write standard ArcForge console
# output and collect matching TXT report lines.
#
# These helpers were extracted in v0.30. Dot-sourcing this file from the main
# script makes these functions available without changing how checks write
# their results.

# Module owner: scripts/ArcForge.ConsoleReport.ps1
# FUTURE MODULE BOUNDARY: these helpers can eventually move into a reporting
# output module because they control console/TXT formatting and summary counts.
# Keep them independent from HTML-specific logic so TXT output remains stable.
#
# Console/TXT ownership rules:
# - Add-ReportLine owns appending raw TXT report lines.
# - Write-Result owns standard [OK] / [WARN] / [FAIL] result formatting.
# - Write-Section owns major console/TXT section headings.
# - Write-Summary owns final summary totals based on $script:CheckCounts.
# - Evidence collection should call these helpers instead of hand-formatting
#   repeated result lines.
# - Data-only helpers should return values and avoid Write-Host/Add-ReportLine
#   side effects unless their purpose is explicitly report output.

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
# Future module owner: scripts/ArcForge.ConsoleReport.ps1
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
# Future module owner: scripts/ArcForge.ConsoleReport.ps1
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
# Future module owner: scripts/ArcForge.ConsoleReport.ps1
function Write-Section {
    param (
        [string]$Title
    )

    Write-Host ""
    Write-Host "[$Title]" -ForegroundColor Gray

    Add-ReportLine -Line ""
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
# Future module owner: scripts/ArcForge.ConsoleReport.ps1
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

