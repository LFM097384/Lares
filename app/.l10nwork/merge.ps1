# Merge per-module ARB fragments into app_zh.arb / app_en.arb.
# Validates key coverage and zh/en parity before writing anything.
$ErrorActionPreference = 'Stop'
$work = 'D:\Projects\Lares\app\.l10nwork'
$final = Get-Content 'D:\Projects\Lares\app\.keys_final.txt' | Where-Object { $_ }
$groups = @('chat','home','p2p','recording','report','room','settings','update','preserved')

$zh = [ordered]@{}
$en = [ordered]@{}
$problems = @()

foreach ($g in $groups) {
    $zf = Join-Path $work "$g.zh.json"
    $ef = Join-Path $work "$g.en.json"
    if (-not (Test-Path $zf)) { $problems += "MISSING $zf"; continue }
    if (-not (Test-Path $ef)) { $problems += "MISSING $ef"; continue }
    try { $zo = Get-Content $zf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $problems += "BAD JSON $zf : $_"; continue }
    try { $eo = Get-Content $ef -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $problems += "BAD JSON $ef : $_"; continue }

    foreach ($p in $zo.PSObject.Properties) {
        if ($zh.Contains($p.Name)) { $problems += "DUP zh key '$($p.Name)' (group $g)" }
        $zh[$p.Name] = $p.Value
    }
    foreach ($p in $eo.PSObject.Properties) {
        if ($p.Name -like '@*') { $problems += "EN has metadata '$($p.Name)' in $g (will drop)"; continue }
        if ($en.Contains($p.Name)) { $problems += "DUP en key '$($p.Name)' (group $g)" }
        $en[$p.Name] = $p.Value
    }
}

$zhKeys = $zh.Keys | Where-Object { $_ -notlike '@*' -and $_ -ne '@@locale' }
$enKeys = $en.Keys | Where-Object { $_ -ne '@@locale' }

$missingZh = $final | Where-Object { $zhKeys -notcontains $_ }
$missingEn = $final | Where-Object { $enKeys -notcontains $_ }
$extraZh   = $zhKeys | Where-Object { $final -notcontains $_ }
$onlyZh    = $zhKeys | Where-Object { $enKeys -notcontains $_ }
$onlyEn    = $enKeys | Where-Object { $zhKeys -notcontains $_ }

"=== MERGE REPORT ==="
"zh value keys: $($zhKeys.Count)   en keys: $($enKeys.Count)   expected: $($final.Count)"
if ($missingZh) { "MISSING IN ZH ($($missingZh.Count)): $($missingZh -join ', ')" }
if ($missingEn) { "MISSING IN EN ($($missingEn.Count)): $($missingEn -join ', ')" }
if ($extraZh)   { "EXTRA IN ZH ($($extraZh.Count)): $($extraZh -join ', ')" }
if ($onlyZh)    { "ZH-ONLY ($($onlyZh.Count)): $($onlyZh -join ', ')" }
if ($onlyEn)    { "EN-ONLY ($($onlyEn.Count)): $($onlyEn -join ', ')" }
foreach ($p in $problems) { "PROBLEM: $p" }

if ($missingZh -or $missingEn -or $onlyZh -or $onlyEn) {
    "`n>>> NOT WRITING ARB - fix the above first."
    exit 1
}

# Build ordered output: @@locale first, then keys sorted, each zh key followed by its @meta
$zhOut = [ordered]@{}
$zhOut['@@locale'] = 'zh'
foreach ($k in ($zhKeys | Sort-Object)) {
    $zhOut[$k] = $zh[$k]
    if ($zh.Contains("@$k")) { $zhOut["@$k"] = $zh["@$k"] }
}
$enOut = [ordered]@{}
$enOut['@@locale'] = 'en'
foreach ($k in ($enKeys | Sort-Object)) { $enOut[$k] = $en[$k] }

$zhJson = $zhOut | ConvertTo-Json -Depth 12
$enJson = $enOut | ConvertTo-Json -Depth 12

# ConvertTo-Json escapes non-ASCII as \uXXXX; unescape back to literal CJK for readability
function Unescape-Unicode([string]$s) {
    [regex]::Replace($s, '\\u([0-9a-fA-F]{4})', { param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}
$zhJson = Unescape-Unicode $zhJson
$enJson = Unescape-Unicode $enJson

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText('D:\Projects\Lares\app\lib\l10n\app_zh.arb', $zhJson, $utf8)
[System.IO.File]::WriteAllText('D:\Projects\Lares\app\lib\l10n\app_en.arb', $enJson, $utf8)
"`n>>> WROTE app_zh.arb ($($zhKeys.Count) keys) and app_en.arb ($($enKeys.Count) keys)"
