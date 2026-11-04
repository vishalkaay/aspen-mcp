# Model-specific setup and results: RadFrac columns and RStoic reactors.

# RadFrac operating specifications -> input keys. A column takes two (one with no condenser or reboiler).
$script:ColSpecKeys = [ordered]@{
    reflux_ratio       = 'BASIS_RR'
    distillate_rate    = 'BASIS_D'
    bottoms_rate       = 'BASIS_B'
    distillate_to_feed = 'D:F'
    bottoms_to_feed    = 'B:F'
    boilup_ratio       = 'BASIS_BR'
    reflux_rate        = 'BASIS_L1'
    boilup_rate        = 'BASIS_VN'
    condenser_duty     = 'Q1'
    reboiler_duty      = 'QN'
}

function Assert-BlockModel([string]$block, [string]$model) {
    $b = Get-AspNode "\Data\Blocks\$block"
    $m = Get-AspAttr $b 6
    if ("$m" -ne $model) { throw "$block is a $m block, not $model" }
}

Register-McpTool -Name 'aspen_radfrac' `
    -Description 'Configure a RadFrac column in one call. Connect its streams first (aspen_connect: F(IN), LD(OUT) liquid distillate, VD(OUT) vapour distillate, B(OUT) bottoms). specs takes exactly two operating specifications (one if there is no condenser or no reboiler) from: reflux_ratio, distillate_rate, bottoms_rate, distillate_to_feed, bottoms_to_feed, boilup_ratio, reflux_rate, boilup_rate, condenser_duty, reboiler_duty. Passing specs replaces the previous ones. Flows and duties are in the simulation units.' `
    -Properties @{
        block = (P-Str 'RadFrac block name'); stages = (P-Int 'Number of stages (incl. condenser and reboiler)')
        condenser = (P-Enum 'Condenser type' @('TOTAL', 'PARTIAL-V', 'PARTIAL-V-L', 'NONE'))
        reboiler = (P-Enum 'Reboiler type' @('KETTLE', 'THERMOSIPHON', 'NONE'))
        feed_stages = (P-Map 'Map of feed stream -> stage, e.g. {"F": 8}')
        feed_convention = (P-Enum 'How feeds enter (default ABOVE-STAGE)' @('ABOVE-STAGE', 'ON-STAGE'))
        pressure = (P-Num 'Top stage (condenser) pressure'); stage_pressure_drop = (P-Num 'Pressure drop per stage')
        specs = (P-Map 'Operating specifications, e.g. {"reflux_ratio": 1.5, "distillate_to_feed": 0.4}')
    } `
    -Required @('block') `
    -Handler {
        param($a)
        Assert-BlockModel $a.block 'RadFrac'
        $c = "\Data\Blocks\$($a.block)\Input"
        $set = [ordered]@{}
        if ($a.stages) { $set["$c\NSTAGE"] = [int]$a.stages }
        if ($a.condenser) { $set["$c\CONDENSER"] = $a.condenser }
        if ($a.reboiler) { $set["$c\REBOILER"] = $a.reboiler }
        $feeds = ConvertTo-Map $a.feed_stages
        foreach ($s in $feeds.Keys) {
            if ($null -eq (Find-AspNode "$c\FEED_STAGE\$s")) { throw "Stream $s is not a feed of $($a.block). Connect it to F(IN) first." }
            $set["$c\FEED_STAGE\$s"] = [int]$feeds[$s]
            if ($a.feed_convention) { $set["$c\FEED_CONVEN\$s"] = $a.feed_convention }
        }
        if ($null -ne $a.pressure) { $set["$c\PRES1"] = $a.pressure }
        if ($null -ne $a.stage_pressure_drop) { $set["$c\DP_STAGE"] = $a.stage_pressure_drop }
        $out = @(Set-AspValues $set)
        $specs = ConvertTo-Map $a.specs
        if ($specs.Count -gt 0) {
            $bad = @($specs.Keys | Where-Object { -not $script:ColSpecKeys.Contains($_) })
            if ($bad.Count) { throw "Unknown spec $($bad -join ', '). Use: $($script:ColSpecKeys.Keys -join ', ')" }
            # Aspen validates the combination on every write, so clear all specs before setting the new pair.
            foreach ($k in $script:ColSpecKeys.Values) { $n = Find-AspNode "$c\$k"; if ($null -ne $n -and "$(Get-AspValue $n)" -ne '') { try { Set-ComProp $n 'Value' '' } catch {} } }
            $sm = [ordered]@{}; foreach ($k in $specs.Keys) { $sm["$c\$($script:ColSpecKeys[$k])"] = $specs[$k] }
            $out += @(Set-AspValues $sm)
        }
        $bad = @($out | Where-Object { $_.error })
        $r = New-JsonResult ([object[]]$out)
        if ($bad.Count) { $r.isError = $true }
        $r
    }

Register-McpTool -Name 'aspen_column_results' `
    -Description 'RadFrac results after a run: summary (condenser and reboiler duty, reflux and boilup ratio, distillate and bottoms flow, top and bottom temperature) and a stage profile (T, P, liquid and vapour flow, stage duty). Add components to include liquid (x) and/or vapour (y) mole fractions per stage.' `
    -Properties @{
        block = (P-Str 'RadFrac block name'); components = (P-StrList 'Components for x/y profiles (default none)')
        phase = (P-Enum 'Which composition profile (default both)' @('x', 'y', 'both'))
    } `
    -Required @('block') `
    -Handler {
        param($a)
        Assert-BlockModel $a.block 'RadFrac'
        $o = "\Data\Blocks\$($a.block)\Output"
        $units = [ordered]@{}
        $sum = [ordered]@{}
        foreach ($p in @(@('condenser_duty', 'COND_DUTY'), @('reboiler_duty', 'REB_DUTY'), @('reflux_ratio', 'MOLE_RR'), @('boilup_ratio', 'MOLE_BR'),
                @('distillate_rate', 'MOLE_D'), @('bottoms_rate', 'MOLE_B'), @('top_temperature', 'TOP_TEMP'), @('bottom_temperature', 'BOTTOM_TEMP'))) {
            $n = Find-AspNode "$o\$($p[1])"
            if ($null -eq $n) { continue }
            $v = ConvertTo-AspOutput (Get-AspValue $n)
            if ($null -eq $v) { continue }
            $sum[$p[0]] = $v
            $u = Get-AspUnits $n; if ($u) { $units[$p[0]] = $u }
        }
        $msg = Find-AspNode "$o\BLKMSG"; if ($msg -and "$(Get-AspValue $msg)".Trim()) { $sum.message = "$(Get-AspValue $msg)".Trim() }
        if ($sum.Count -eq 0) { return New-ErrorResult "No results for $($a.block) yet. Run the simulation first." }
        $T = Read-AspVector "$o\B_TEMP" $units 'T'
        $P = Read-AspVector "$o\B_PRES" $units 'P'
        $L = Read-AspVector "$o\LIQ_FLOW" $units 'L'
        $V = Read-AspVector "$o\VAP_FLOW" $units 'V'
        $Q = Read-AspVector "$o\DUTY" $units 'duty'
        $comps = @($a.components | ForEach-Object { "$_".ToUpper() })
        $phase = if ($a.phase) { $a.phase } else { 'both' }
        $prof = @()
        foreach ($st in $T.Keys) {
            $row = [ordered]@{ stage = [int]$st; T = $T[$st] }
            if ($P) { $row.P = $P[$st] }
            if ($L) { $row.L = $L[$st] }
            if ($V) { $row.V = $V[$st] }
            if ($Q -and $Q[$st]) { $row.duty = $Q[$st] }
            foreach ($ph in @('x', 'y')) {
                if ($comps.Count -eq 0 -or ($phase -ne 'both' -and $phase -ne $ph)) { continue }
                $vec = Read-AspVector "$o\$($ph.ToUpper())\$st" $null $null
                if ($vec) { $m = [ordered]@{}; foreach ($cp in $comps) { if ($vec.Contains($cp)) { $m[$cp] = $vec[$cp] } }; $row[$ph] = $m }
            }
            $prof += $row
        }
        New-JsonResult ([ordered]@{ block = $a.block; units = $units; summary = $sum; profile = [object[]]$prof })
    }

Register-McpTool -Name 'aspen_rstoic' `
    -Description 'Configure an RStoic reactor: operating conditions plus the reaction list, which replaces any existing reactions. Each reaction: {"reactants": {"ETOH": 1, "ACID": 1}, "products": {"ETAC": 1, "WATER": 1}, "conversion": 0.6, "key": "ACID"} (fractional conversion of the key component) or {"...", "extent": 6} (molar extent in the simulation units). Coefficients are positive numbers. Set temperature+pressure, or pressure+duty (duty 0 = adiabatic).' `
    -Properties @{
        block = (P-Str 'RStoic block name'); temperature = (P-Num 'Temperature'); pressure = (P-Num 'Pressure'); duty = (P-Num 'Heat duty (use with pressure)')
        reactions = @{ type = 'array'; description = 'Reactions in order'; items = @{ type = 'object' } }
        series = (P-Bool 'Reactions occur in series (default false: simultaneous)')
    } `
    -Required @('block') `
    -Handler {
        param($a)
        Assert-BlockModel $a.block 'RStoic'
        $r = "\Data\Blocks\$($a.block)\Input"
        $set = [ordered]@{}
        if ($null -ne $a.duty) { $set["$r\SPEC_OPT"] = 'PD'; $set["$r\DUTY"] = $a.duty }
        elseif ($null -ne $a.temperature) { $set["$r\SPEC_OPT"] = 'TP'; $set["$r\TEMP"] = $a.temperature }
        if ($null -ne $a.pressure) { $set["$r\PRES"] = $a.pressure }
        if ($null -ne $a.series) { $set["$r\SERIES"] = $(if ($a.series) { 'YES' } else { 'NO' }) }
        $out = @(Set-AspValues $set)
        if ($null -ne $a.reactions) {
            $old = Get-AspChildNames "$r\COEF"
            foreach ($id in $old) { Remove-AspRow "$r\COEF" $id }
            $i = 0
            foreach ($rx in @($a.reactions)) {
                $i++; $id = "$i"
                $reac = ConvertTo-Map $rx.reactants; $prod = ConvertTo-Map $rx.products
                if ($reac.Count -eq 0 -or $prod.Count -eq 0) { throw "Reaction $i needs reactants and products" }
                [void](Add-AspRow "$r\COEF" $id)   # also creates the COEF1, CONV and KEY_CID rows
                foreach ($cp in $reac.Keys) { [void](Add-AspRow2 "$r\COEF\$id" $cp.ToUpper() 'MIXED') }
                foreach ($cp in $prod.Keys) { [void](Add-AspRow2 "$r\COEF1\$id" $cp.ToUpper() 'MIXED') }
                $m = [ordered]@{}
                foreach ($cp in $reac.Keys) { $m["$r\COEF\$id\$($cp.ToUpper())\MIXED"] = -[math]::Abs([double]$reac[$cp]) }
                foreach ($cp in $prod.Keys) { $m["$r\COEF1\$id\$($cp.ToUpper())\MIXED"] = [math]::Abs([double]$prod[$cp]) }
                if ($null -ne $rx.extent) {
                    $m["$r\OPT_EXT_CONV\$id"] = 'EXTENT'; $m["$r\EXTENT\$id"] = $rx.extent
                } else {
                    if ($null -eq $rx.conversion -or -not $rx.key) { throw "Reaction $i needs conversion + key, or extent" }
                    $m["$r\OPT_EXT_CONV\$id"] = 'CONVERSION'; $m["$r\KEY_CID\$id"] = "$($rx.key)".ToUpper(); $m["$r\KEY_SSID\$id"] = 'MIXED'; $m["$r\CONV\$id"] = $rx.conversion
                }
                $out += @(Set-AspValues $m)
            }
        }
        $bad = @($out | Where-Object { $_.error })
        $ids = Get-AspChildNames "$r\COEF"
        $res = New-JsonResult ([ordered]@{ block = $a.block; reactions = $ids.Count; settings = [object[]]$out })
        if ($bad.Count) { $res.isError = $true }
        $res
    }
