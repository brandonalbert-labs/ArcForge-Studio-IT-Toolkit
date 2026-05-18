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
# v0.37 extraction scope:
# - ConvertTo-HtmlSafeText remains the shared HTML encoding helper.
# - New-StatusClass owns small status-to-CSS-class lookups used by the HTML
#   report.
# - New-StatusBadgeHtml owns simple status badge markup used by the HTML report.
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
