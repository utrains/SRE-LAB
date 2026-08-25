param(
    [string]$ChromePath,
    [switch]$KeepBuild
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SourceDir = Join-Path $RepoRoot 'docs\incident-scenarios'
$OutputDir = Join-Path $RepoRoot 'docs\pdf'
$BuildDir = Join-Path $OutputDir '.build'

$Scenarios = @(
    @{ Source = '01-bad-container-image.md'; Output = '01-bad-image-deployment.pdf' },
    @{ Source = '02-bad-configmap-rollout.md'; Output = '02-bad-config-rollout.pdf' },
    @{ Source = '03-oomkilled-resource-limits.md'; Output = '03-oomkilled.pdf' },
    @{ Source = '04-alb-ingress-routing.md'; Output = '04-ingress-routing-failure.pdf' },
    @{ Source = '05-high-application-latency.md'; Output = '05-high-latency.pdf' }
)

if (-not $ChromePath) {
    $Candidates = @(
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
    )
    $ChromePath = $Candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $ChromePath -or -not (Test-Path -LiteralPath $ChromePath)) {
    throw 'Chrome or Edge was not found. Pass -ChromePath with the browser executable path.'
}

New-Item -ItemType Directory -Force -Path $OutputDir, $BuildDir | Out-Null

function Convert-Inline([string]$Text) {
    $value = [System.Net.WebUtility]::HtmlEncode($Text)
    $value = [regex]::Replace($value, '`([^`]+)`', '<code>$1</code>')
    $value = [regex]::Replace($value, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    $value = [regex]::Replace($value, '\[([^\]]+)\]\(([^)]+)\)', '<a href="$2">$1</a>')
    return $value
}

function Convert-Markdown([string]$Markdown) {
    $lines = $Markdown -split "`r?`n"
    $html = [System.Text.StringBuilder]::new()
    $paragraph = [System.Collections.Generic.List[string]]::new()
    $inCode = $false
    $code = [System.Collections.Generic.List[string]]::new()
    $listType = $null
    $tableRows = [System.Collections.Generic.List[object]]::new()

    function Flush-Paragraph {
        if ($paragraph.Count -gt 0) {
            [void]$html.Append('<p>' + (Convert-Inline ($paragraph -join ' ')) + '</p>')
            $paragraph.Clear()
        }
    }
    function Close-List {
        if ($listType) { [void]$html.Append("</$listType>"); Set-Variable -Name listType -Value $null -Scope 1 }
    }
    function Flush-Table {
        if ($tableRows.Count -gt 0) {
            [void]$html.Append('<table>')
            for ($i = 0; $i -lt $tableRows.Count; $i++) {
                $tag = if ($i -eq 0) { 'th' } else { 'td' }
                [void]$html.Append('<tr>')
                foreach ($cell in $tableRows[$i]) { [void]$html.Append("<$tag>$(Convert-Inline $cell)</$tag>") }
                [void]$html.Append('</tr>')
            }
            [void]$html.Append('</table>')
            $tableRows.Clear()
        }
    }

    foreach ($line in $lines) {
        if ($line -match '^```') {
            Flush-Paragraph; Close-List; Flush-Table
            if ($inCode) {
                [void]$html.Append('<pre><code>' + [System.Net.WebUtility]::HtmlEncode(($code -join "`n")) + '</code></pre>')
                $code.Clear(); $inCode = $false
            } else { $inCode = $true }
            continue
        }
        if ($inCode) { $code.Add($line); continue }

        if ($line -match '^\|.*\|$') {
            Flush-Paragraph; Close-List
            $cells = @($line.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
            if (($cells | Where-Object { $_ -notmatch '^:?-{3,}:?$' }).Count -eq 0) { continue }
            $tableRows.Add($cells); continue
        } else { Flush-Table }

        if ($line -match '^(#{1,6})\s+(.+)$') {
            Flush-Paragraph; Close-List
            $level = $matches[1].Length
            [void]$html.Append("<h$level>$(Convert-Inline $matches[2])</h$level>")
        } elseif ($line -match '^[-*]\s+(.+)$') {
            Flush-Paragraph
            if ($listType -ne 'ul') { Close-List; [void]$html.Append('<ul>'); $listType = 'ul' }
            [void]$html.Append('<li>' + (Convert-Inline $matches[1]) + '</li>')
        } elseif ($line -match '^\d+\.\s+(.+)$') {
            Flush-Paragraph
            if ($listType -ne 'ol') { Close-List; [void]$html.Append('<ol>'); $listType = 'ol' }
            [void]$html.Append('<li>' + (Convert-Inline $matches[1]) + '</li>')
        } elseif ([string]::IsNullOrWhiteSpace($line)) {
            Flush-Paragraph; Close-List
        } else { $paragraph.Add($line.Trim()) }
    }
    Flush-Paragraph; Close-List; Flush-Table
    return $html.ToString()
}

$Style = @'
@page { size: Letter; margin: 0.7in 0.72in 0.7in; @bottom-center { content: "Page " counter(page) " of " counter(pages); font: 9pt Arial; color: #64748b; } }
* { box-sizing: border-box; }
body { color: #172033; font: 10.5pt/1.48 Arial, sans-serif; margin: 0; }
h1 { color: #123b63; font-size: 24pt; line-height: 1.15; margin: 0 0 20pt; border-bottom: 3px solid #2b77b5; padding-bottom: 9pt; }
h2 { color: #174f7e; font-size: 15pt; margin: 19pt 0 7pt; break-after: avoid-page; }
h3 { color: #285f89; font-size: 12pt; margin: 13pt 0 5pt; break-after: avoid-page; }
p { margin: 0 0 8pt; }
ul, ol { margin: 4pt 0 10pt 20pt; padding: 0; }
li { margin: 2pt 0; }
code { font-family: Consolas, 'Courier New', monospace; font-size: 9pt; background: #eef2f6; padding: 1px 3px; border-radius: 2px; overflow-wrap: anywhere; }
pre { background: #172033; color: #f8fafc; padding: 10pt; border-radius: 4px; white-space: pre-wrap; overflow-wrap: anywhere; break-inside: avoid-page; margin: 7pt 0 11pt; }
pre code { color: inherit; background: transparent; padding: 0; }
table { border-collapse: collapse; width: 100%; margin: 8pt 0 13pt; font-size: 9pt; break-inside: avoid-page; }
th, td { border: 1px solid #aab7c4; padding: 5pt; text-align: left; vertical-align: top; }
th { background: #dbeaf5; color: #123b63; }
a { color: #155f9b; text-decoration: none; }
.scenario { break-before: page; }
.scenario:first-child { break-before: auto; }
'@

function New-Html([string]$Title, [string]$Body) {
    return "<!doctype html><html><head><meta charset='utf-8'><title>$([System.Net.WebUtility]::HtmlEncode($Title))</title><style>$Style</style></head><body>$Body</body></html>"
}

function Print-Pdf([string]$HtmlPath, [string]$PdfPath) {
    $uri = ([System.Uri]$HtmlPath).AbsoluteUri
    $profile = Join-Path $BuildDir ([System.IO.Path]::GetFileNameWithoutExtension($HtmlPath) + '-profile')
    $arguments = @('--headless=new', '--disable-gpu', '--no-pdf-header-footer', "--user-data-dir=$profile", "--print-to-pdf=$PdfPath", $uri)
    $process = Start-Process -FilePath $ChromePath -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $PdfPath) -or (Get-Item $PdfPath).Length -lt 1000) {
        throw "PDF generation failed for $PdfPath"
    }
}

$combined = [System.Text.StringBuilder]::new()
foreach ($scenario in $Scenarios) {
    $sourcePath = Join-Path $SourceDir $scenario.Source
    if (-not (Test-Path -LiteralPath $sourcePath)) { throw "Missing Markdown source: $sourcePath" }
    $markdown = Get-Content -Raw -LiteralPath $sourcePath
    $body = Convert-Markdown $markdown
    $htmlPath = Join-Path $BuildDir ($scenario.Source -replace '\.md$', '.html')
    [System.IO.File]::WriteAllText($htmlPath, (New-Html $scenario.Source $body), [System.Text.UTF8Encoding]::new($false))
    Print-Pdf $htmlPath (Join-Path $OutputDir $scenario.Output)
    [void]$combined.Append('<section class="scenario">' + $body + '</section>')
}

$combinedHtml = Join-Path $BuildDir 'sre-lab-devops-scenarios.html'
[System.IO.File]::WriteAllText($combinedHtml, (New-Html 'SRE Lab DevOps Scenarios' $combined.ToString()), [System.Text.UTF8Encoding]::new($false))
Print-Pdf $combinedHtml (Join-Path $OutputDir 'sre-lab-devops-scenarios.pdf')

$starSourcePath = Join-Path $RepoRoot 'docs\devops-star-scenarios.md'
if (-not (Test-Path -LiteralPath $starSourcePath)) { throw "Missing Markdown source: $starSourcePath" }
$starMarkdown = Get-Content -Raw -LiteralPath $starSourcePath
$starBody = Convert-Markdown $starMarkdown
$starHtml = Join-Path $BuildDir 'devops-star-scenarios.html'
[System.IO.File]::WriteAllText($starHtml, (New-Html 'DevOps STAR Scenarios' $starBody), [System.Text.UTF8Encoding]::new($false))
Print-Pdf $starHtml (Join-Path $OutputDir 'devops-star-scenarios.pdf')

$guideSourcePath = Join-Path $RepoRoot 'README.md'
if (-not (Test-Path -LiteralPath $guideSourcePath)) { throw "Missing Markdown source: $guideSourcePath" }
$guideMarkdown = Get-Content -Raw -LiteralPath $guideSourcePath
$guideBody = Convert-Markdown $guideMarkdown
$guideHtml = Join-Path $BuildDir 'sre-lab-launch-guide.html'
[System.IO.File]::WriteAllText($guideHtml, (New-Html 'SRE Lab Launch Guide' $guideBody), [System.Text.UTF8Encoding]::new($false))
Print-Pdf $guideHtml (Join-Path $OutputDir 'sre-lab-launch-guide.pdf')

if (-not $KeepBuild) {
    Remove-Item -LiteralPath $BuildDir -Recurse -Force
}
Write-Output "Generated $($Scenarios.Count) scenario PDFs, one combined PDF, one DevOps STAR PDF, and one launch guide PDF in $OutputDir"
