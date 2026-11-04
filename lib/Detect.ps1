# Aspen Plus version detection, shared by the server, install.ps1 and check.ps1.
# Aspen Plus registers Apwn.Document.<n>.0 per installed version (37 = V11, 38 = V12, 39 = V13,
# 40 = V14, 41 = V15) plus a version-independent Apwn.Document. "auto" picks the newest one.

# Direct lookups of the known names: enumerating all of HKEY_CLASSES_ROOT takes ~40 s on a cold cache.
function Get-AspProgIds {
    $ids = @()
    for ($n = 50; $n -ge 30; $n--) {
        $k = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("Apwn.Document.$n.0\CLSID")
        if ($null -ne $k) { $k.Close(); $ids += "Apwn.Document.$n.0" }
    }
    return $ids
}

function Resolve-AspProgId([string]$configured) {
    if ($configured -and $configured -ne 'auto') { return $configured }
    $ids = @(Get-AspProgIds)   # @() keeps a single result a list (else [0] is its first letter)
    if ($ids.Count -gt 0) { return $ids[0] }
    return 'Apwn.Document'
}

function Get-AspVersionName([string]$progid) {
    if ($progid -match '\.(\d+)\.0$') {
        $n = [int]$Matches[1]
        $names = @{ 36 = 'V10'; 37 = 'V11'; 38 = 'V12'; 39 = 'V13'; 40 = 'V14'; 41 = 'V15'; 42 = 'V16' }
        if ($names.ContainsKey($n)) { return "Aspen Plus $($names[$n])" }
    }
    return $progid
}
