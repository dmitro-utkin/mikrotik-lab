[CmdletBinding()]
param(
    [string]$InputPath = ".\manual\MikroTik-local-editable-gateway.rsc",
    [string]$OutputPath = ".\manual\MikroTik-local-editable-gateway-colored.html"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function ConvertTo-HtmlText {
    param([AllowEmptyString()][string]$Text)

    return [System.Net.WebUtility]::HtmlEncode($Text)
}

$resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path
if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
}
else {
    $resolvedOutput = [System.IO.Path]::GetFullPath(
        (Join-Path (Get-Location) $OutputPath)
    )
}

$sourceLines = Get-Content -LiteralPath $resolvedInput -Encoding UTF8
$renderedLines = New-Object System.Text.StringBuilder
$editableBlock = $false

for ($index = 0; $index -lt $sourceLines.Count; $index++) {
    $line = [string]$sourceLines[$index]
    $trimmed = $line.Trim()
    $lineNumber = $index + 1

    if ($trimmed.Length -eq 0) {
        $editableBlock = $false
    }

    $isComment = $trimmed.StartsWith("#")
    $startsEditableBlock = $isComment -and (
        $trimmed.Contains("EDIT:") -or
        $trimmed.Contains("EDIT BLOCK")
    )

    if ($startsEditableBlock) {
        $editableBlock = $true
    }

    $containsPlaceholder = (
        $line.Contains("EDIT-") -or
        $line.Contains("CHANGE-ME-")
    )

    $cssClass = if ($containsPlaceholder -or $startsEditableBlock -or (-not $isComment -and $editableBlock)) {
        "editable"
    }
    elseif ($isComment) {
        "comment"
    }
    elseif ($trimmed.Length -eq 0) {
        "blank"
    }
    else {
        "command"
    }

    $encodedLine = ConvertTo-HtmlText -Text $line
    [void]$renderedLines.AppendLine(
        "<div class=""line $cssClass""><span class=""number"">$lineNumber</span><span class=""text"">$encodedLine</span></div>"
    )
}

$title = [System.IO.Path]::GetFileName($resolvedInput)
$html = @"
<!doctype html>
<html lang="uk">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$title - &#1082;&#1086;&#1083;&#1100;&#1086;&#1088;&#1086;&#1074;&#1072; &#1087;&#1110;&#1076;&#1082;&#1072;&#1079;&#1082;&#1072;</title>
  <style>
    :root {
      color-scheme: light;
      --background: #f5f7fa;
      --panel: #ffffff;
      --border: #d7dde7;
      --text: #1f2937;
      --muted: #6b7280;
      --command: #075bc4;
      --editable: #c62828;
      --comment: #667085;
      --line-number: #9aa4b2;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      background: var(--background);
      color: var(--text);
      font-family: Arial, sans-serif;
    }

    main {
      width: min(1500px, calc(100% - 32px));
      margin: 24px auto;
    }

    h1 {
      margin: 0 0 8px;
      font-size: 24px;
    }

    .notice {
      margin: 0 0 16px;
      color: var(--muted);
      line-height: 1.5;
    }

    .legend {
      display: flex;
      flex-wrap: wrap;
      gap: 16px;
      margin-bottom: 16px;
      padding: 14px 16px;
      border: 1px solid var(--border);
      border-radius: 10px;
      background: var(--panel);
    }

    .legend span {
      font-family: Consolas, "Courier New", monospace;
      font-weight: 700;
    }

    .legend .command-key {
      color: var(--command);
    }

    .legend .editable-key {
      color: var(--editable);
    }

    .legend .comment-key {
      color: var(--comment);
    }

    .code {
      overflow: auto;
      padding: 14px 0;
      border: 1px solid var(--border);
      border-radius: 10px;
      background: var(--panel);
      box-shadow: 0 4px 18px rgba(15, 23, 42, 0.06);
      font: 14px/1.55 Consolas, "Courier New", monospace;
      tab-size: 4;
    }

    .line {
      display: grid;
      grid-template-columns: 64px minmax(max-content, 1fr);
      min-height: 22px;
      padding-right: 18px;
      white-space: pre;
    }

    .line:hover {
      background: #f0f4f9;
    }

    .number {
      padding-right: 16px;
      color: var(--line-number);
      text-align: right;
      user-select: none;
    }

    .command .text {
      color: var(--command);
      font-weight: 600;
    }

    .editable .text {
      color: var(--editable);
      font-weight: 700;
      background: #fff0f0;
    }

    .comment .text {
      color: var(--comment);
    }

    .blank .text {
      color: transparent;
    }
  </style>
</head>
<body>
  <main>
    <h1>$title</h1>
    <p class="notice">
      &#1050;&#1086;&#1083;&#1100;&#1086;&#1088;&#1086;&#1074;&#1072; &#1074;&#1077;&#1088;&#1089;&#1110;&#1103; &#1087;&#1088;&#1080;&#1079;&#1085;&#1072;&#1095;&#1077;&#1085;&#1072; &#1083;&#1080;&#1096;&#1077; &#1076;&#1083;&#1103; &#1095;&#1080;&#1090;&#1072;&#1085;&#1085;&#1103;. &#1044;&#1083;&#1103; RouterOS &#1074;&#1080;&#1082;&#1086;&#1088;&#1080;&#1089;&#1090;&#1086;&#1074;&#1091;&#1081;&#1090;&#1077; &#1074;&#1080;&#1093;&#1110;&#1076;&#1085;&#1080;&#1081; &#1092;&#1072;&#1081;&#1083;
      <strong>$title</strong>.
    </p>
    <div class="legend">
      <span class="command-key">&#1057;&#1080;&#1085;&#1110;&#1081;: RouterOS-&#1082;&#1086;&#1084;&#1072;&#1085;&#1076;&#1080;</span>
      <span class="editable-key">&#1063;&#1077;&#1088;&#1074;&#1086;&#1085;&#1080;&#1081;: &#1079;&#1085;&#1072;&#1095;&#1077;&#1085;&#1085;&#1103; &#1072;&#1073;&#1086; &#1073;&#1083;&#1086;&#1082;&#1080; &#1076;&#1083;&#1103; &#1088;&#1077;&#1076;&#1072;&#1075;&#1091;&#1074;&#1072;&#1085;&#1085;&#1103;</span>
      <span class="comment-key">&#1057;&#1110;&#1088;&#1080;&#1081;: &#1087;&#1086;&#1103;&#1089;&#1085;&#1077;&#1085;&#1085;&#1103; &#1090;&#1072; &#1082;&#1086;&#1084;&#1077;&#1085;&#1090;&#1072;&#1088;&#1110;</span>
    </div>
    <section class="code" aria-label="RouterOS configuration source">
$($renderedLines.ToString())
    </section>
  </main>
</body>
</html>
"@

$outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutput)
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedOutput, $html, $utf8NoBom)

Write-Host "Generated color guide: $resolvedOutput"
