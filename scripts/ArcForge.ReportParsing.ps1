# ArcForge First Response
# Report Parsing Helpers Module
#
# This module owns read-only interpretation helpers for completed ArcForge
# report lines. These helpers sit between the console/TXT reporting path and
# the static HTML report renderer.
#
# Plain-language ownership rule:
# - This file may read report lines that were already collected.
# - This file may group or structure those lines for later rendering.
# - This file should not run endpoint checks.
# - This file should not write console or TXT output.
# - This file should not mutate $ReportLines.
# - This file should not change readiness scoring.
# - This file should not own HTML, CSS, navigation markup, or final file writing.

# Groups raw TXT report lines into known report sections.
#
# The HTML report does not run checks again. Instead, it reads the lines already
# captured in $ReportLines and sorts them under major section names. Only known
# sections are captured so accidental bracketed lines do not create random cards.
#
# Boundary note:
# - This is interpretation logic, not presentation logic.
# - It knows the canonical section headings and section ordering used by the
#   report pipeline.
# - It should stay independent from CSS, card markup, sidebar markup, and final
#   file writing.
#
# Input:
# - ReportLines: The full collected report output.
# Output:
# - Hashtable where each known section name maps to a list of lines.
# Module owner: scripts/ArcForge.ReportParsing.ps1
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
