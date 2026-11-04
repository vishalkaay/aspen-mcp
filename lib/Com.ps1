# COM helpers for Aspen Plus (Apwn.Document).
#
# Two PowerShell 5.1 pitfalls shape everything here:
#  1. The PS COM adapter exposes Aspen's Value/Name/Label as "parameterized properties" that cannot
#     be read or written normally, so all access goes through reflection (InvokeMember).
#  2. A function that returns a COM collection (or a node that has children) gets enumerated into
#     its items on the way out. Every helper therefore returns with the unary comma (return ,$x),
#     and returns nothing at all for $null.
# Also: never name a helper like a built-in alias (sv, gp, sp, set, mv ...). Verb-Noun names are safe.

$script:BF = [Reflection.BindingFlags]
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# Cmdlet output (Join-Path, Get-Content ...) arrives wrapped in PSObject, which COM rejects with
# DISP_E_TYPEMISMATCH, so every argument is unwrapped to its base object first.
function ConvertTo-ComArgs($argList) {
    if ($null -eq $argList) { return $null }
    $out = New-Object object[] (@($argList).Count)
    $i = 0
    foreach ($x in @($argList)) { $out[$i++] = if ($x -is [psobject]) { $x.PSObject.BaseObject } else { $x } }
    return ,$out
}
function Get-ComProp($o, [string]$name, $argList = $null) {
    $r = $o.GetType().InvokeMember($name, $script:BF::GetProperty, $null, $o, (ConvertTo-ComArgs $argList))
    if ($null -eq $r) { return }
    return ,$r
}
function Set-ComProp($o, [string]$name, $value) {
    [void]$o.GetType().InvokeMember($name, $script:BF::SetProperty, $null, $o, (ConvertTo-ComArgs @(, $value)))
}
function Set-ComPropArgs($o, [string]$name, [object[]]$argList) {
    [void]$o.GetType().InvokeMember($name, $script:BF::SetProperty, $null, $o, (ConvertTo-ComArgs $argList))
}
function Invoke-ComMethod($o, [string]$name, $argList = $null) {
    $r = $o.GetType().InvokeMember($name, $script:BF::InvokeMethod, $null, $o, (ConvertTo-ComArgs $argList))
    if ($null -eq $r) { return }
    return ,$r
}

# Innermost exception message (COM errors arrive wrapped in TargetInvocationException).
function Get-ErrorText($err) {
    $e = if ($err -is [System.Management.Automation.ErrorRecord]) { $err.Exception } else { $err }
    $msgs = @()
    while ($e) { if ($e.Message -and $msgs -notcontains $e.Message) { $msgs += $e.Message }; $e = $e.InnerException }
    if ($msgs.Count -gt 1) { $msgs = $msgs | Where-Object { $_ -notmatch '^Exception (calling|has been thrown)' } }
    ($msgs -join ' | ')
}

function ConvertTo-AspInput($v) {
    # ConvertFrom-Json in PS 5.1 yields Decimal for fractions; COM wants a double.
    if ($v -is [decimal] -or $v -is [single]) { return [double]$v }
    if ($v -is [long]) { if ($v -ge [int]::MinValue -and $v -le [int]::MaxValue) { return [int]$v } else { return [double]$v } }
    return $v
}

function ConvertTo-Double($v) {
    $x = 0.0
    if ($null -eq $v) { return $null }
    if ([double]::TryParse("$v", [Globalization.NumberStyles]::Float, $script:Inv, [ref]$x)) { return $x }
    return $null
}

# ---- variable tree ----
function Get-AspApp {
    if (-not (Test-AspSession)) { throw 'No Aspen simulation is open. Use aspen_new or aspen_open first.' }
    return ,$global:S.App
}
function Find-AspNode([string]$path) {
    $tree = Get-ComProp (Get-AspApp) 'Tree'
    $n = Invoke-ComMethod $tree 'FindNode' @($path)
    if ($null -eq $n) { return }
    return ,$n
}
function Get-AspNode([string]$path) {
    $n = Find-AspNode $path
    if ($null -eq $n) { throw "Node not found: $path (use aspen_list or aspen_find on the parent to see valid names)" }
    return ,$n
}
function Get-AspValue($n) { try { return (Get-ComProp $n 'Value') } catch { return $null } }
function Get-AspName($n) { try { return [string](Get-ComProp $n 'Name') } catch { return $null } }
function Get-AspUnits($n) { try { $u = Get-ComProp $n 'UnitString'; if ("$u" -ne '') { return "$u" } } catch {}; return $null }
function Get-AspAttr($n, [int]$i) { try { return $n.AttributeValue($i) } catch { return $null } }
function Set-AspValue($n, $v) { Set-ComProp $n 'Value' (ConvertTo-AspInput $v) }

function Get-AspChildren($n) {
    $list = New-Object System.Collections.ArrayList
    $c = $null
    try { $c = Get-ComProp $n 'Elements' } catch {}
    if ($null -ne $c) { foreach ($e in $c) { [void]$list.Add($e) } }
    return ,$list
}
function Get-AspChildNames([string]$path) {
    $n = Find-AspNode $path
    if ($null -eq $n) { return ,@() }
    $names = @(); foreach ($e in (Get-AspChildren $n)) { $names += (Get-AspName $e) }
    return ,$names
}
function Get-AspCollection([string]$path) {
    $n = Get-AspNode $path
    $c = Get-ComProp $n 'Elements'
    if ($null -eq $c) { throw "Node has no element collection: $path" }
    return ,$c
}
function Add-AspElement([string]$path, [string]$name) {
    $c = Get-AspCollection $path
    [void](Invoke-ComMethod $c 'Add' @($name))
}
function Remove-AspElement([string]$path, [string]$name) {
    $c = Get-AspCollection $path
    [void](Invoke-ComMethod $c 'Remove' @($name))
}
# Table-style nodes (component lists, flow tables, heat-curve keys) grow by inserting a labelled row.
function Add-AspRow([string]$path, [string]$label) {
    $c = Get-AspCollection $path
    $rn = Get-ComProp $c 'RowCount' @([int]0)
    [void](Invoke-ComMethod $c 'InsertRow' @([int]0, [int]$rn))
    Set-ComPropArgs $c 'Label' @([int]0, [int]$rn, "$label")
    return $rn
}
function Remove-AspRow([string]$path, [string]$label) {
    $c = Get-AspCollection $path
    $rows = Get-ComProp $c 'RowCount' @([int]0)
    for ($i = 0; $i -lt $rows; $i++) {
        if ("$(Get-ComProp $c 'Label' @([int]0, [int]$i))" -ieq $label) {
            [void](Invoke-ComMethod $c 'RemoveRow' @([int]0, [int]$i))
            return
        }
    }
    throw "No row '$label' under $path"
}

# Value + units of one node as an ordered dictionary.
function Read-AspNode([string]$path) {
    $n = Find-AspNode $path
    if ($null -eq $n) { return [ordered]@{ path = $path; error = 'node not found' } }
    $o = [ordered]@{ path = $path; value = (Get-AspValue $n) }
    $u = Get-AspUnits $n; if ($u) { $o.units = $u }
    $k = (Get-AspChildren $n).Count; if ($k -gt 0) { $o.children = $k }
    return $o
}
function Read-AspNumber([string]$path) {
    $n = Find-AspNode $path
    if ($null -eq $n) { return $null }
    return (ConvertTo-Double (Get-AspValue $n))
}
