# End-to-end test of the model tools against a real Aspen Plus V14 (opens an Aspen window, ~3-5 minutes):
# a methanol/water RadFrac column, an esterification RStoic, a design spec, a sensitivity study and solids.
#   powershell -ExecutionPolicy Bypass -File tests\models.tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'McpClient.ps1')

function Get-Row($rows, [string]$key, [string]$value) { @($rows | Where-Object { $_.$key -eq $value })[0] }
function Invoke-Run([string]$what) {
    $r = Invoke-Tool 'aspen_run' @{ wait_seconds = 240 } 300
    Assert-True (-not $r.isError -and -not $r.json.running) "run ($what) finishes: $($r.json.status)" $r.text
    return $r
}

[void](Start-McpServer (Join-Path $root 'server.ps1'))
try {
    [void](Invoke-Mcp 'initialize' @{ protocolVersion = '2025-06-18' })
    $r = Invoke-Tool 'aspen_new' @{ unit_set = 'METCBAR'; replace = $true }
    Assert-True (-not $r.isError) 'new METCBAR simulation' $r.text
    $r = Invoke-Tool 'aspen_add_components' @{ components = @('WATER', 'MEOH=METHANOL', 'ETOH=ETHANOL', 'ACID=ACETIC-ACID', 'ETAC=ETHYL-ACETATE') }
    Assert-True (@($r.json.components | Where-Object { -not $_.found }).Count -eq 0) 'five components found' $r.text
    [void](Invoke-Tool 'aspen_set_property_method' @{ method = 'NRTL' })

    Write-Host 'RadFrac column'
    foreach ($s in 'F', 'D', 'B', 'RF', 'RP') { [void](Invoke-Tool 'aspen_add_stream' @{ name = $s }) }
    [void](Invoke-Tool 'aspen_add_block' @{ name = 'C1'; model = 'RadFrac' })
    foreach ($cn in @(@('F(IN)', 'F'), @('LD(OUT)', 'D'), @('B(OUT)', 'B'))) { [void](Invoke-Tool 'aspen_connect' @{ block = 'C1'; port = $cn[0]; stream = $cn[1] }) }
    [void](Invoke-Tool 'aspen_set_stream' @{ name = 'F'; temperature = 70; pressure = 1.5; flow_basis = 'MOLE'; component_flows = @{ WATER = 60; MEOH = 40 } })
    $r = Invoke-Tool 'aspen_radfrac' @{ block = 'C1'; stages = 15; condenser = 'TOTAL'; feed_stages = @{ F = 8 }; pressure = 1.013; specs = @{ reflux_ratio = 1.5; distillate_to_feed = 0.4 } }
    Assert-True (-not $r.isError -and @($r.json).Count -eq 6 -and @($r.json | Where-Object { $_ -is [array] }).Count -eq 0) 'aspen_radfrac sets stages, condenser, feed stage, pressure and two specs (6 flat rows)' $r.text
    $r = Invoke-Tool 'aspen_radfrac' @{ block = 'C1'; specs = @{ reflux_ratio = 1.5; distillate_rate = 40 } }
    Assert-True (-not $r.isError) 'replacing the spec pair (D:F -> distillate rate) is accepted' $r.text
    $r = Invoke-Tool 'aspen_get' @{ paths = @('\Data\Blocks\C1\Input\D:F', '\Data\Blocks\C1\Input\BASIS_D') }
    Assert-True ("$(@($r.json)[0].value)" -eq '' -and [double]@($r.json)[1].value -eq 40) 'the old spec is cleared' $r.text
    $r = Invoke-Tool 'aspen_radfrac' @{ block = 'C1'; specs = @{ reflux_ratio = 1.5; distillate_to_feed = 0.4 } }
    $r = Invoke-Tool 'aspen_radfrac' @{ block = 'C1'; specs = @{ purity = 0.9 } }
    Assert-True ($r.isError -and $r.text -match 'Unknown spec') 'unknown spec names are rejected with the list' $r.text
    $r = Invoke-Tool 'aspen_rstoic' @{ block = 'C1'; temperature = 50 }
    Assert-True ($r.isError -and $r.text -match 'not RStoic') 'model tools check the block type' $r.text

    Write-Host 'RStoic reactor'
    [void](Invoke-Tool 'aspen_add_block' @{ name = 'R1'; model = 'RStoic' })
    [void](Invoke-Tool 'aspen_connect' @{ block = 'R1'; port = 'F(IN)'; stream = 'RF' })
    [void](Invoke-Tool 'aspen_connect' @{ block = 'R1'; port = 'P(OUT)'; stream = 'RP' })
    [void](Invoke-Tool 'aspen_set_stream' @{ name = 'RF'; temperature = 70; pressure = 1.2; flow_basis = 'MOLE'; component_flows = @{ ETOH = 10; ACID = 10 } })
    $r = Invoke-Tool 'aspen_run' @{ wait_seconds = 30 } 90
    Assert-True ($r.isError -and (@($r.json.incomplete) -match '^block R1').Count -eq 1) "aspen_run refuses incomplete input and names it ($(@($r.json.incomplete) -join ', '))" $r.text
    $rx = @{ reactants = @{ ETOH = 1; ACID = 1 }; products = @{ ETAC = 1; WATER = 1 }; conversion = 0.3; key = 'ACID' }
    $r = Invoke-Tool 'aspen_rstoic' @{ block = 'R1'; temperature = 70; pressure = 1.2; reactions = @($rx) }
    Assert-True (-not $r.isError -and $r.json.reactions -eq 1) 'aspen_rstoic defines one reaction' $r.text
    $rx.conversion = 0.6
    $r = Invoke-Tool 'aspen_rstoic' @{ block = 'R1'; reactions = @($rx) }
    Assert-True (-not $r.isError -and $r.json.reactions -eq 1) 'calling again replaces the reaction list' $r.text
    $r = Invoke-Tool 'aspen_info'
    Assert-True ((@($r.json.incomplete_input) -match 'R1').Count -eq 0) "aspen_info: R1 no longer incomplete ($(@($r.json.incomplete_input) -join ', '))" $r.text

    Invoke-Run 'column + reactor' | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Tool 'aspen_column_results' @{ block = 'C1'; components = @('MEOH', 'WATER') }
    $sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $s = $r.json.summary; $p = @($r.json.profile)
    Assert-True (-not $r.isError -and $p.Count -eq 15) "column profile has 15 stages ($sec s)" $r.text
    Assert-True ([math]::Abs($s.reflux_ratio - 1.5) -lt 1e-6 -and [math]::Abs($s.distillate_rate - 40) -lt 1e-4) "summary: RR $($s.reflux_ratio), D $($s.distillate_rate) $($r.json.units.distillate_rate)" $r.text
    Assert-True ($s.condenser_duty -lt 0 -and $s.reboiler_duty -gt 0) "duties: condenser $($s.condenser_duty), reboiler $($s.reboiler_duty) $($r.json.units.reboiler_duty)" $r.text
    Assert-True ($p[0].T -lt $p[14].T -and $r.json.units.T -eq 'C') "temperature rises down the column ($($p[0].T) -> $($p[14].T) C)" $r.text
    Assert-True ($p[0].x.MEOH -gt 0.9 -and $p[14].x.WATER -gt 0.9) "x profile: top MEOH $($p[0].x.MEOH), bottom WATER $($p[14].x.WATER)" $r.text
    $r = Invoke-Tool 'aspen_streams' @{ names = @('RP'); basis = 'mole' }
    $rp = @($r.json.streams)[0]
    Assert-True ([math]::Abs($rp.components.ETAC - 6) -lt 1e-6 -and [math]::Abs($rp.components.ACID - 4) -lt 1e-6) "RStoic: 60% of ACID converted (ETAC $($rp.components.ETAC), ACID $($rp.components.ACID) kmol/hr)" $r.text
    $r = Invoke-Tool 'aspen_block_results' @{ block = 'R1'; filter = 'QCALC|R_CONV|REAC' }
    Assert-True (-not $r.isError -and $r.text -match 'QCALC') 'aspen_block_results on the reactor' $r.text

    Write-Host 'design spec'
    $xd = @{ type = 'MOLE-FRAC'; stream = 'D'; component = 'MEOH' }
    $rr = @{ type = 'BLOCK-VAR'; block = 'C1'; sentence = 'COL-SPECS'; variable = 'MOLE-RR' }
    $r = Invoke-Tool 'aspen_design_spec' @{ name = 'DS-1'; define = @{ XD = $xd }; expression = 'XD'; target = 0.99; tolerance = 0.0001; vary = $rr; lower = 0.5; upper = 10 }
    Assert-True (-not $r.isError) 'aspen_design_spec creates DS-1' $r.text
    Invoke-Run 'design spec' | Out-Null
    $r = Invoke-Tool 'aspen_analysis_results' @{ name = 'DS-1' }
    $d = @($r.json)[0]
    Assert-True ([math]::Abs($d.spec_value - 0.99) -lt 2e-4 -and $d.status -eq 0) "DS-1 converged: XD = $($d.spec_value) at reflux ratio $($d.vary_final)" $r.text
    $r = Invoke-Tool 'aspen_info'
    Assert-True (@($r.json.design_specs) -contains 'DS-1') 'aspen_info lists design specs' $r.text
    $r = Invoke-Tool 'aspen_delete' @{ kind = 'design-spec'; name = 'DS-1' }
    Assert-True (-not $r.isError) 'aspen_delete removes the design spec' $r.text

    Write-Host 'sensitivity'
    $vary = $rr.Clone(); $vary.lower = 1; $vary.upper = 3; $vary.points = 3
    $def = @{ QREB = @{ type = 'BLOCK-VAR'; block = 'C1'; sentence = 'RESULTS'; variable = 'REB-DUTY' }; XD = $xd }
    $r = Invoke-Tool 'aspen_sensitivity' @{ name = 'S-1'; vary = @($vary); define = $def; tabulate = @('QREB', 'XD') }
    Assert-True (-not $r.isError) 'aspen_sensitivity creates S-1' $r.text
    Invoke-Run 'sensitivity' | Out-Null
    $r = Invoke-Tool 'aspen_analysis_results' @{ name = 'S-1' }
    $t = @($r.json)[0]; $rows = @($t.rows); $cols = @($t.columns)
    # Aspen tabulates the base case too (sorted in), so 3 points can give 4 rows.
    Assert-True ($rows.Count -ge 3 -and $cols.Count -eq 3) "sensitivity table: $($rows.Count) cases x $($cols.Count) columns ($($cols -join ' | '))" $r.text
    if ($rows.Count -ge 3) {
        $q = @($rows | ForEach-Object { $_.($cols[1]) }); $x = @($rows | ForEach-Object { $_.($cols[2]) }); $v = @($rows | ForEach-Object { $_.($cols[0]) })
        Assert-True ($v -contains 1 -and $v -contains 2 -and $v -contains 3) "vary column covers 1, 2, 3 ($($v -join ', '))" $r.text
        $up = $true; for ($k = 1; $k -lt $v.Count; $k++) { if ($q[$k] -le $q[$k - 1] -or $x[$k] -lt $x[$k - 1]) { $up = $false } }
        Assert-True $up "reboiler duty and purity rise with reflux ($($q -join ', ') / $($x -join ', '))" $r.text
        Assert-True (@($rows | Where-Object { $_.status -ne 'ok' }).Count -eq 0) 'all cases ok' $r.text
    }

    Write-Host 'solids'
    $r = Invoke-Tool 'aspen_add_components' @{ components = @('CACO3=CALCIUM-CARBONATE'); type = 'SOLID' }
    Assert-True (-not $r.isError -and $r.json.components[0].found -and $r.json.stream_class -eq 'MIXCISLD') "solid component added, stream class $($r.json.stream_class)" $r.text
    foreach ($s in 'S1', 'S2') { [void](Invoke-Tool 'aspen_add_stream' @{ name = $s }) }
    [void](Invoke-Tool 'aspen_add_block' @{ name = 'H1'; model = 'Heater' })
    [void](Invoke-Tool 'aspen_connect' @{ block = 'H1'; port = 'F(IN)'; stream = 'S1' })
    [void](Invoke-Tool 'aspen_connect' @{ block = 'H1'; port = 'P(OUT)'; stream = 'S2' })
    [void](Invoke-Tool 'aspen_set_stream' @{ name = 'S1'; temperature = 25; pressure = 2; flow_basis = 'MASS'; component_flows = @{ WATER = 1000 } })
    $r = Invoke-Tool 'aspen_set_stream' @{ name = 'S1'; substream = 'CISOLID'; temperature = 25; pressure = 2; flow_basis = 'MASS'; component_flows = @{ CACO3 = 100 } }
    Assert-True (-not $r.isError -and @($r.json | Where-Object { $_.error }).Count -eq 0) 'CISOLID feed set' $r.text
    [void](Invoke-Tool 'aspen_set' @{ values = @{ '\Data\Blocks\H1\Input\SPEC_OPT' = 'TP'; '\Data\Blocks\H1\Input\TEMP' = 80; '\Data\Blocks\H1\Input\PRES' = 1.5 } })
    Invoke-Run 'solids' | Out-Null
    $r = Invoke-Tool 'aspen_streams' @{ names = @('S2') }
    $s2 = @($r.json.streams)[0]
    Assert-True ([math]::Abs($s2.substreams.CISOLID.components.CACO3 - 100) -lt 1e-6 -and [math]::Abs($s2.substreams.CISOLID.T - 80) -lt 0.01) "S2 CISOLID: CACO3 $($s2.substreams.CISOLID.components.CACO3) kg/hr at $($s2.substreams.CISOLID.T) C" $r.text
    Assert-True ([math]::Abs($s2.mass_flow_total - 1100) -lt 1e-4) "mass_flow_total over substreams = $($s2.mass_flow_total)" $r.text

    Write-Host 'speed'
    $sw.Restart()
    $r = Invoke-Tool 'aspen_tree' @{ path = '\Data\Blocks\C1\Input'; depth = 2 }
    $sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Assert-True (-not $r.isError -and $r.text -match 'NSTAGE = 15' -and $sec -lt 30) "aspen_tree on the RadFrac input in $sec s" $r.text
    $r = Invoke-Tool 'aspen_find' @{ root = '\Data\Blocks\C1\Output'; pattern = '^REB_DUTY$'; depth = 1 }
    Assert-True ($null -ne @($r.json.hits)[0].value -and @($r.json.hits)[0].value -isnot [string]) 'aspen_find returns numbers as numbers' $r.text
    $r = Invoke-Tool 'aspen_save' @{ file = 'models_test.bkp'; overwrite = $true }
    Assert-True (-not $r.isError) "saved $($r.json.saved)" $r.text
} finally {
    try { [void](Invoke-Tool 'aspen_close' @{} 30) } catch {}
    Stop-McpServer
}
Write-Summary
if ($script:Failed -gt 0) { exit 1 }
