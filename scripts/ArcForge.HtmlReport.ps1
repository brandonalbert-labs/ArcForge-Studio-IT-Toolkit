# ArcForge First Response - HTML Report Helpers
#
# This module supports ArcForge's static HTML report.
#
# Important boundaries:
# - Keep the HTML report local, self-contained, auditable, and dependency-free.
# - Do not collect endpoint evidence in this module.
# - Do not run health checks in this module.
# - Do not change readiness scoring in this module.
# - Do not write console or TXT report output in this module.
# - Do not add JavaScript, CDN assets, remote fonts, remote icons, remote images,
#   or external dependencies in this module.
#
# v0.39 extraction scope:
# - ConvertTo-HtmlSafeText remains the shared HTML encoding helper.
# - New-StatusClass owns small status-to-CSS-class lookups used by the HTML
#   report.
# - New-StatusBadgeHtml owns simple status badge markup used by the HTML report.
# - ConvertTo-ArcForgeHtmlFindingList owns generic finding-line list markup used
#   by the HTML report.
# - Get-ArcForgeFlattenedLines owns generic line flattening used by the HTML
#   report.
# - New-ArcForgeHtmlReport remains in Invoke-ArcForgeFirstResponse.ps1 for now.
# - Future releases can move additional HTML helpers in small, tested slices.

function ConvertTo-HtmlSafeText {
    param (
        [string]$Text
    )

    # Encode text before placing it into HTML.
    #
    # This prevents report values containing characters like <, >, or & from
    # breaking the HTML structure or being interpreted as markup.
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function New-StatusClass {
    param (
        [string]$Status,
        [string]$ClassPrefix = "status"
    )

    # Map an existing ArcForge status label to the matching static HTML CSS
    # class. This is presentation-only; it does not change findings, scoring, or
    # console/TXT report output.
    switch ($Status) {
        "OK"                    { return "$ClassPrefix-ok" }
        "WARN"                  { return "$ClassPrefix-warn" }
        "FAIL"                  { return "$ClassPrefix-fail" }
        "Healthy"               { return "$ClassPrefix-ok" }
        "Attention Recommended" { return "$ClassPrefix-warn" }
        "Action Required"       { return "$ClassPrefix-fail" }
        default                 { return "$ClassPrefix-unknown" }
    }
}

function New-StatusBadgeHtml {
    param (
        [string]$Status,
        [string]$StatusClass,
        [string]$BadgeClass = "status-badge"
    )

    # Build a small status badge for the static HTML report.
    #
    # The status text is encoded before it is inserted into markup. The CSS class
    # values are controlled by ArcForge helper logic, not endpoint input.
    $SafeStatus = ConvertTo-HtmlSafeText $Status

    return "<span class=`"$BadgeClass $StatusClass`">$SafeStatus</span>"
}

function ConvertTo-ArcForgeHtmlFindingList {
    param (
        [object[]]$Lines,
        [string]$EmptyMessage = "No findings captured for this section. See Raw Findings for the complete report output."
    )

    # Convert raw finding lines into an HTML <li> list.
    #
    # Some section line collections can be nested arrays, especially when multiple
    # report sections are combined into one HTML card. This helper flattens them,
    # removes blanks, HTML-encodes every line, and wraps each finding in <code>.
    #
    # Output:
    # - A string containing one or more <li> elements.
    # - A muted placeholder <li> when the section has no findings.
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

