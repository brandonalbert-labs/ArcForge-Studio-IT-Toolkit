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
# v0.36 extraction scope:
# - ConvertTo-HtmlSafeText is the first safe helper extracted from the main
#   renderer.
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
