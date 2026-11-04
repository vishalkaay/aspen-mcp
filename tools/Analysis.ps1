# Model analysis: design specs and sensitivity studies.
#
# Both reference flowsheet variables the same way Aspen's "Define" and "Vary" sheets do. A variable
# reference is an object with a type plus the fields that type needs:
#   {"type": "BLOCK-VAR", "block": "C1", "sentence": "COL-SPECS", "variable": "MOLE-RR"}
#   {"type": "MOLE-FRAC", "stream": "D", "component": "MEOH"}        (substream defaults to MIXED)
# Define rows are stored as FVN_<field>\<name>; a design spec's vary as VARY<field>; a sensitivity's
# vary rows as VARY<field>\#<n>.

$script:DsRoot = '\Data\Flowsheeting Options\Design-Spec'
$script:SensRoot = '\Data\Model Analysis Tools\Sensitivity'
# reference field -> (define suffix, vary suffix); set in this order
$script:RefFields = [ordered]@{
    type = @('VARTYPE', '_VARTYPE'); block = @('BLOCK', 'BLOCK'); stream = @('STREAM', 'STREAM'); substream = @('SUBS', 'SUBS')
    component = @('COMPONEN', 'COMPONEN'); sentence = @('SENTENCE', 'SENTENCE'); variable = @('VARIABLE', 'VARIABLE')
    id1 = @('ID1', 'ID1'); id2 = @('ID2', 'ID2'); element = @('ELEM', 'ELEM')
}
$script:RefSchema = @{ type = 'object'; description = 'Variable reference: {"type": "BLOCK-VAR"|"STREAM-VAR"|"MOLE-FLOW"|"MASS-FLOW"|"MOLE-FRAC"|"MASS-FRAC"|..., "block", "stream", "substream" (default MIXED), "component", "sentence", "variable", "id1", "id2"}' }

# ordered path -> value map for one variable reference
function ConvertTo-RefPaths($ref, [string]$base, [string]$suffix, [bool]$isVary) {
    $m = ConvertTo-Map $ref
    if (-not $m.Contains('type')) { throw 'A variable reference needs a type (BLOCK-VAR, STREAM-VAR, MOLE-FLOW, MOLE-FRAC ...)' }
    if ($m.Contains('stream') -and -not $m.Contains('substream')) { $m['substream'] = 'MIXED' }
    $set = [ordered]@{}
    foreach ($f in $script:RefFields.Keys) {
        if (-not $m.Contains($f)) { continue }
        $key = if ($isVary) { 'VARY' + $script:RefFields[$f][1] } else { 'FVN_' + $script:RefFields[$f][0] }
        $v = $m[$f]; if ($v -is [string]) { $v = $v.ToUpper() }
        $set["$base\$key$suffix"] = $v
    }
    $unknown = @($m.Keys | Where-Object { -not $script:RefFields.Contains($_) })
    if ($unknown.Count) { throw "Unknown reference field(s) $($unknown -join ', '). Use: $($script:RefFields.Keys -join ', ')" }
    return $set
}

function New-AnalysisObject([string]$root, [string]$name) {
    if ($null -ne (Find-AspNode "$root\$name")) { Remove-AspElement $root $name }
    Add-AspElement $root $name
}

function Add-DefineRows([string]$base, $define) {
    $out = @()
    $defs = ConvertTo-Map $define
    foreach ($vn in $defs.Keys) {
        $id = $vn.ToUpper()
        [void](Add-AspRow "$base\FVN_VARTYPE" $id)
        $out += @(Set-AspValues (ConvertTo-RefPaths $defs[$vn] $base "\$id" $false))
    }
    return $out
}

function Get-ResultRows($r, [string]$what) {
    $bad = @($r | Where-Object { $_.error })
    $res = New-JsonResult ([ordered]@{ created = $what; settings = [object[]]$r })
    if ($bad.Count) { $res.isError = $true }
    $res
}

Register-McpTool -Name 'aspen_design_spec' `
    -Description 'Create (or replace) a design spec: Aspen adjusts one vary variable between lower and upper until the expression equals target within tolerance. define names the measured variables used in the expression. Examples of references: RadFrac reflux ratio {"type":"BLOCK-VAR","block":"C1","sentence":"COL-SPECS","variable":"MOLE-RR"}; Heater outlet temperature {"type":"BLOCK-VAR","block":"H1","sentence":"PARAM","variable":"TEMP"}; feed component flow {"type":"MOLE-FLOW","stream":"F","component":"WATER"}; product purity {"type":"MOLE-FRAC","stream":"D","component":"MEOH"}. Run the simulation afterwards and read it with aspen_analysis_results.' `
    -Properties @{
        name = (P-Str 'Design spec ID, e.g. DS-1'); define = (P-Map 'Map of variable name -> reference, e.g. {"XD": {"type":"MOLE-FRAC","stream":"D","component":"MEOH"}}')
        expression = (P-Str 'Spec expression, usually a defined variable name, e.g. XD'); target = (P-Any 'Target value or expression'); tolerance = (P-Num 'Tolerance')
        vary = $script:RefSchema; lower = (P-Num 'Lower bound of the vary variable'); upper = (P-Num 'Upper bound of the vary variable')
    } `
    -Required @('name', 'define', 'expression', 'target', 'tolerance', 'vary', 'lower', 'upper') `
    -Handler {
        param($a)
        $name = $a.name.ToUpper()
        New-AnalysisObject $script:DsRoot $name
        $b = "$script:DsRoot\$name\Input"
        $out = @(Add-DefineRows $b $a.define)
        $m = [ordered]@{ "$b\EXPR1" = $a.expression; "$b\EXPR2" = "$($a.target)"; "$b\TOL" = $a.tolerance }
        $out += @(Set-AspValues $m)
        $out += @(Set-AspValues (ConvertTo-RefPaths $a.vary $b '' $true))
        $out += @(Set-AspValues ([ordered]@{ "$b\LOWER" = $a.lower; "$b\UPPER" = $a.upper }))
        Get-ResultRows $out "design spec $name"
    }

Register-McpTool -Name 'aspen_sensitivity' `
    -Description 'Create (or replace) a sensitivity study: each vary entry is a variable reference plus a range, {"type":"BLOCK-VAR","block":"C1","sentence":"COL-SPECS","variable":"MOLE-RR","lower":1,"upper":3,"points":5} (or "increment" instead of points, or "values":[...] for a list). define names the tabulated variables; tabulate lists the expressions to report (default: every defined name). References are as in aspen_design_spec, e.g. reboiler duty {"type":"BLOCK-VAR","block":"C1","sentence":"RESULTS","variable":"REB-DUTY"}. Run the simulation, then read the table with aspen_analysis_results (Aspen also tabulates the base case, sorted in, so expect one extra row). A design spec acting on the same variable fights the sensitivity: delete or adjust it first.' `
    -Properties @{
        name = (P-Str 'Sensitivity ID, e.g. S-1')
        vary = @{ type = 'array'; description = 'Vary entries (reference + lower/upper/points|increment, or values)'; items = @{ type = 'object' } }
        define = (P-Map 'Map of variable name -> reference'); tabulate = (P-StrList 'Expressions to tabulate (default: all defined names)')
    } `
    -Required @('name', 'vary', 'define') `
    -Handler {
        param($a)
        $name = $a.name.ToUpper()
        New-AnalysisObject $script:SensRoot $name
        $b = "$script:SensRoot\$name\Input"
        $out = @()
        $i = 0
        foreach ($v in @($a.vary)) {
            $vm = ConvertTo-Map $v
            $row = "#$i"
            if ($null -eq (Find-AspNode "$b\VARY_VARTYPE\$row")) { [void](Add-AspRow "$b\VARY_VARTYPE" $null) }
            $ref = [ordered]@{}; foreach ($k in $vm.Keys) { if (@('lower', 'upper', 'points', 'increment', 'values') -notcontains $k) { $ref[$k] = $vm[$k] } }
            $out += @(Set-AspValues (ConvertTo-RefPaths $ref $b "\$row" $true))
            $m = [ordered]@{}
            if ($vm.Contains('values')) {
                $m["$b\OPT_LIST\$row"] = 'LIST'
                $m["$b\LIST\$row"] = (@($vm['values']) | ForEach-Object { ([double]$_).ToString([Globalization.CultureInfo]::InvariantCulture) }) -join ' '
            } else {
                $m["$b\OPT_LIST\$row"] = 'RANGE'; $m["$b\LOWER\$row"] = $vm['lower']; $m["$b\UPPER\$row"] = $vm['upper']
                if ($vm.Contains('increment')) { $m["$b\OPT_RANGE\$row"] = 'INCR'; $m["$b\INCR\$row"] = $vm['increment'] }
                else { $m["$b\OPT_RANGE\$row"] = 'NPOINT'; $m["$b\NPOINT\$row"] = $(if ($vm.Contains('points')) { $vm['points'] } else { 5 }) }
            }
            $out += @(Set-AspValues $m)
            $i++
        }
        $out += @(Add-DefineRows $b $a.define)
        $tab = if ($a.tabulate) { @($a.tabulate) } else { @((ConvertTo-Map $a.define).Keys | ForEach-Object { $_.ToUpper() }) }
        $j = 0
        foreach ($t in $tab) {
            $j++
            if ($null -eq (Find-AspNode "$b\EXPR\$j")) { [void](Add-AspRow "$b\EXPR" "$j") }
            $out += @(Set-AspValues ([ordered]@{ "$b\EXPR\$j" = $t }))
        }
        Get-ResultRows $out "sensitivity $name"
    }

function Get-OutputLines([string]$path) {
    $o = @()
    $n = Find-AspNode $path
    if ($null -eq $n) { return ,$o }
    $vals = [AspCom]::ChildValues($n)
    foreach ($k in $vals.Keys) { $s = "$($vals[$k])".Trim(); if ($s) { $o += $s } }
    return ,$o
}

function Get-DesignSpecResult([string]$name) {
    $b = "$script:DsRoot\$name"
    $o = [ordered]@{ name = $name; kind = 'design-spec' }
    $o.expression = Get-AspValue (Find-AspNode "$b\Input\EXPR1")
    $o.target = Get-AspValue (Find-AspNode "$b\Input\EXPR2")
    $o.tolerance = ConvertTo-AspOutput (Get-AspValue (Find-AspNode "$b\Input\TOL"))
    $fin = Read-AspVector "$b\Output\FINAL_VAL" $null $null
    if ($fin -and $fin.Count -gt 0) {
        $o.vary_final = $fin['1']
        $u = Get-AspValue (Find-AspNode "$b\Output\VAR_UNIT\1"); if ("$u".Trim()) { $o.vary_units = "$u".Trim() }
        $o.spec_value = $fin['2']
        $init = Read-AspVector "$b\Output\INIT_VAL" $null $null
        if ($init) { $o.vary_initial = $init['1'] }
    } else { $o.note = 'no results (run the simulation)' }
    $st = Get-AspValue (Find-AspNode "$b\Output\BLKSTAT"); if ($null -ne $st) { $o.status = $st; $o.status_note = '0 = converged' }
    $err = Get-OutputLines "$b\Output\PER_ERROR"; if ($err.Count) { $o.messages = [object[]]$err }
    $o
}

function Get-SensitivityResult([string]$name) {
    $b = "$script:SensRoot\$name\Output"
    $o = [ordered]@{ name = $name; kind = 'sensitivity' }
    $data = Find-AspNode "$b\SENSVAR"
    $rows = if ($data) { [AspCom]::Children($data) } else { @() }
    if ($rows.Count -eq 0) { $o.note = 'no results (run the simulation)'; return $o }
    # Column headers: LINE1 (VARY n / expression), LINE2-4 (block, sentence, variable), LINE5-7 (units)
    $lines = @{}; foreach ($k in 1..7) { $lines[$k] = Read-AspVector "$b\LINE$k" $null $null }
    $ncol = [AspCom]::ChildCount([AspCom]::Children($data)[0])
    $cols = @()
    for ($c = 1; $c -le $ncol; $c++) {
        $parts = @(); foreach ($k in 1..4) { $v = if ($lines[$k]) { $lines[$k]["$c"] } else { $null }; if ("$v".Trim()) { $parts += "$v".Trim() } }
        $label = ($parts -join ' ') -replace '\s+', ' '
        $unit = @(); foreach ($k in 5..7) { $v = if ($lines[$k]) { $lines[$k]["$c"] } else { $null }; if ("$v".Trim()) { $unit += "$v".Trim() } }
        if ($unit.Count) { $label += " [$($unit -join ' ')]" }
        if (-not $label) { $label = "col$c" }
        $cols += $label
    }
    $stat = Read-AspVector "$b\ROWSTAT" $null $null
    $table = @()
    foreach ($r in $rows) {
        $rn = [AspCom]::Name($r)
        $vals = [AspCom]::ChildValues($r)
        $row = [ordered]@{ case = [int]$rn }
        for ($c = 1; $c -le $cols.Count; $c++) { $row[$cols[$c - 1]] = ConvertTo-AspOutput $vals["$c"] }
        $s = if ($stat) { $stat[$rn] } else { $null }
        $row.status = if ($null -eq $s -or $s -eq 0) { 'ok' } elseif ($s -eq 1) { 'warnings' } else { 'errors' }
        $table += $row
    }
    $o.columns = [object[]]$cols
    $o.rows = [object[]]$table
    $err = Get-OutputLines "$b\PER_ERROR"; if ($err.Count) { $o.messages = [object[]]$err }
    $o
}

Register-McpTool -Name 'aspen_analysis_results' `
    -Description 'Results of design specs (final value of the vary variable, achieved spec value, status) and sensitivity studies (the full table, one row per case with the vary and tabulated values). Omit name to get every design spec and sensitivity in the simulation.' `
    -Properties @{ name = (P-Str 'Design spec or sensitivity ID (default all)') } `
    -Handler {
        param($a)
        $out = @()
        $ds = Get-AspChildNames $script:DsRoot; $se = Get-AspChildNames $script:SensRoot
        foreach ($n in $ds) { if (-not $a.name -or $n -ieq $a.name) { $out += Get-DesignSpecResult $n } }
        foreach ($n in $se) { if (-not $a.name -or $n -ieq $a.name) { $out += Get-SensitivityResult $n } }
        if ($a.name -and $out.Count -eq 0) { throw "No design spec or sensitivity named $($a.name)" }
        New-JsonResult ([object[]]$out)
    }
