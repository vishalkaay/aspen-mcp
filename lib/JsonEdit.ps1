# Minimal-diff JSON editing for config files owned by other programs (Claude Desktop, Claude Code).
# Instead of parsing and re-serialising the whole file (which reformats it and, in PowerShell 5.1,
# can mangle large or unusual documents), these functions locate one member by scanning the text
# and replace, insert or remove only that span. Every result is validated before it is written.

function Skip-JsonWs([string]$t, [int]$i) {
    while ($i -lt $t.Length -and [char]::IsWhiteSpace($t[$i])) { $i++ }
    return $i
}

function Skip-JsonString([string]$t, [int]$i) {
    $i++
    while ($i -lt $t.Length) {
        $c = $t[$i]
        if ($c -eq [char]'\') { $i += 2; continue }
        if ($c -eq [char]'"') { return $i + 1 }
        $i++
    }
    throw 'Unterminated string in JSON'
}

# Index just past the value that starts at (or after whitespace from) $i.
function Skip-JsonValue([string]$t, [int]$i) {
    $i = Skip-JsonWs $t $i
    $c = $t[$i]
    if ($c -eq [char]'"') { return Skip-JsonString $t $i }
    if ($c -eq [char]'{' -or $c -eq [char]'[') {
        $d = 0
        while ($i -lt $t.Length) {
            $c = $t[$i]
            if ($c -eq [char]'"') { $i = Skip-JsonString $t $i; continue }
            if ($c -eq [char]'{' -or $c -eq [char]'[') { $d++ }
            elseif ($c -eq [char]'}' -or $c -eq [char]']') { $d--; if ($d -eq 0) { return $i + 1 } }
            $i++
        }
        throw 'Unbalanced brackets in JSON'
    }
    while ($i -lt $t.Length -and ',}]'.IndexOf($t[$i]) -lt 0 -and -not [char]::IsWhiteSpace($t[$i])) { $i++ }
    return $i
}

# Members of the object whose '{' is at $objStart: Key, KeyStart, ValueStart, ValueEnd (exclusive).
function Get-JsonMembers([string]$t, [int]$objStart) {
    $out = New-Object System.Collections.ArrayList
    $i = $objStart + 1
    while ($true) {
        $i = Skip-JsonWs $t $i
        if ($i -ge $t.Length) { throw 'Unexpected end of JSON' }
        if ($t[$i] -eq [char]'}') { break }
        if ($t[$i] -eq [char]',') { $i++; continue }
        $ks = $i; $ke = Skip-JsonString $t $i
        $i = Skip-JsonWs $t $ke
        if ($t[$i] -ne [char]':') { throw "Expected ':' at $i" }
        $vs = Skip-JsonWs $t ($i + 1); $ve = Skip-JsonValue $t $vs
        [void]$out.Add([pscustomobject]@{ Key = $t.Substring($ks + 1, $ke - $ks - 2); KeyStart = $ks; ValueStart = $vs; ValueEnd = $ve })
        $i = $ve
    }
    return ,$out
}

function Get-JsonRootStart([string]$t) {
    $i = Skip-JsonWs $t 0
    if ($i -ge $t.Length -or $t[$i] -ne [char]'{') { throw 'Config file is not a JSON object' }
    return $i
}

# Set root.<section>.<name> = $valueJson (a JSON text), creating the section if needed.
function Set-JsonSectionEntry([string]$t, [string]$section, [string]$name, [string]$valueJson) {
    if ([string]::IsNullOrWhiteSpace($t)) { $t = '{}' }
    $root = Get-JsonRootStart $t
    $rootMembers = Get-JsonMembers $t $root   # assign before piping: the list comes back as one object
    $sec = $rootMembers | Where-Object { $_.Key -eq $section } | Select-Object -First 1
    if (-not $sec) {
        $hasMembers = $rootMembers.Count -gt 0
        $ins = "`n  `"$section`": {`n    `"$name`": $valueJson`n  }" + $(if ($hasMembers) { ',' } else { "`n" })
        return $t.Substring(0, $root + 1) + $ins + $t.Substring($root + 1)
    }
    if ($t[$sec.ValueStart] -ne [char]'{') { throw "$section is not an object" }
    $members = Get-JsonMembers $t $sec.ValueStart
    $cur = $members | Where-Object { $_.Key -eq $name } | Select-Object -First 1
    if ($cur) { return $t.Substring(0, $cur.ValueStart) + $valueJson + $t.Substring($cur.ValueEnd) }
    $ins = "`n    `"$name`": $valueJson" + $(if ($members.Count -gt 0) { ',' } else { "`n  " })
    return $t.Substring(0, $sec.ValueStart + 1) + $ins + $t.Substring($sec.ValueStart + 1)
}

# Remove root.<section>.<name>; returns the text unchanged when it is not there.
function Remove-JsonSectionEntry([string]$t, [string]$section, [string]$name) {
    if ([string]::IsNullOrWhiteSpace($t)) { return $t }
    $root = Get-JsonRootStart $t
    $rootMembers = Get-JsonMembers $t $root
    $sec = $rootMembers | Where-Object { $_.Key -eq $section } | Select-Object -First 1
    if (-not $sec -or $t[$sec.ValueStart] -ne [char]'{') { return $t }
    $members = Get-JsonMembers $t $sec.ValueStart
    $cur = $members | Where-Object { $_.Key -eq $name } | Select-Object -First 1
    if (-not $cur) { return $t }
    $start = $cur.KeyStart; $end = $cur.ValueEnd
    $after = Skip-JsonWs $t $end
    $b = $start - 1
    while ($b -gt $sec.ValueStart -and [char]::IsWhiteSpace($t[$b])) { $b-- }
    if ($t[$after] -eq [char]',') { $start = $b + 1; $end = $after + 1 }   # member, its leading space and its comma
    elseif ($t[$b] -eq [char]',') { $start = $b }                          # last member: the comma before it
    else { $start = $b + 1; $end = $after }                                # only member: leaves {}
    $t = $t.Substring(0, $start) + $t.Substring($end)
    # A section that Set-JsonSectionEntry created (first member, own line) and that is now empty goes too.
    foreach ($form in @("`n  `"$section`": {},", "`n  `"$section`": {}`n")) {
        if ($t.Length -gt $root + $form.Length -and $t.Substring($root + 1, $form.Length) -eq $form) {
            return $t.Substring(0, $root + 1) + $t.Substring($root + 1 + $form.Length)
        }
    }
    return $t
}
