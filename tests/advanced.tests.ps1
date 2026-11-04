# End-to-end test of kinetic reactors, calculators and input help against a real Aspen Plus V14
# (opens an Aspen window, ~2 minutes).
#   powershell -ExecutionPolicy Bypass -File tests\advanced.tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'McpClient.ps1')

function Get-Stream($r, [string]$name) { @($r.json.streams | Where-Object { $_.stream -eq $name })[0] }

[void](Start-McpServer (Join-Path $root 'server.ps1'))
try {
    [void](Invoke-Mcp 'initialize' @{ protocolVersion = '2025-06-18' })
    [void](Invoke-Tool 'aspen_new' @{ unit_set = 'METCBAR'; replace = $true })
    $r = Invoke-Tool 'aspen_add_components' @{ components = @('WATER', 'ETOH=ETHANOL', 'ACID=ACETIC-ACID', 'ETAC=ETHYL-ACETATE') }
    Assert-True (@($r.json.components | Where-Object { -not $_.found }).Count -eq 0) 'components found' $r.text
    [void](Invoke-Tool 'aspen_set_property_method' @{ method = 'NRTL' })
    foreach ($s in 'F1', 'P1', 'F2', 'P2', 'F3', 'P3') { [void](Invoke-Tool 'aspen_add_stream' @{ name = $s }) }
    foreach ($b in @(@('R2', 'RCSTR', 'F1', 'P1'), @('R3', 'RPlug', 'F2', 'P2'), @('H1', 'Heater', 'F3', 'P3'))) {
        [void](Invoke-Tool 'aspen_add_block' @{ name = $b[0]; model = $b[1] })
        [void](Invoke-Tool 'aspen_connect' @{ block = $b[0]; port = 'F(IN)'; stream = $b[2] })
        [void](Invoke-Tool 'aspen_connect' @{ block = $b[0]; port = 'P(OUT)'; stream = $b[3] })
    }
    foreach ($s in 'F1', 'F2') { [void](Invoke-Tool 'aspen_set_stream' @{ name = $s; temperature = 70; pressure = 1.2; component_flows = @{ ETOH = 10; ACID = 10 } }) }
    [void](Invoke-Tool 'aspen_set_stream' @{ name = 'F3'; temperature = 25; pressure = 1.2; component_flows = @{ ETOH = 10; ACID = 1 } })

    Write-Host 'input help'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Tool 'aspen_describe_inputs' @{ target = 'H1'; filter = '^SPEC_OPT$|^TEMP$' }
    $spec = @($r.json.fields | Where-Object { $_.field -eq 'SPEC_OPT' })[0]
    $temp = @($r.json.fields | Where-Object { $_.field -eq 'TEMP' })[0]
    Assert-True ($spec.options -match '(^|,)TP(,|$)' -and $spec.help) "Heater SPEC_OPT options ($($spec.options.Substring(0, [math]::Min(30, $spec.options.Length)))...) and help '$($spec.help)' in $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s" $r.text
    Assert-True ($temp.units -eq 'C' -and $temp.help -match 'temperature') "Heater TEMP: $($temp.units), '$($temp.help)'" $r.text
    $r = Invoke-Tool 'aspen_describe_inputs' @{ target = 'R3'; filter = 'length|diam|type' }
    Assert-True (-not $r.isError -and @($r.json.fields).Count -ge 3) "RPlug fields found by help text ($(@($r.json.fields | ForEach-Object { $_.field }) -join ', '))" $r.text
    $r = Invoke-Tool 'aspen_describe_inputs' @{ target = 'NOPE' }
    Assert-True ($r.isError) 'unknown target is an error' $r.text
    [void](Invoke-Tool 'aspen_set' @{ values = @{ '\Data\Blocks\H1\Input\SPEC_OPT' = 'TP'; '\Data\Blocks\H1\Input\TEMP' = 50; '\Data\Blocks\H1\Input\PRES' = 1.2 } })

    Write-Host 'kinetic reactors'
    $rx = @{ reactants = @{ ETOH = 1; ACID = 1 }; products = @{ ETAC = 1; WATER = 1 }; k = 1e-5; E = 0; phase = 'L' }
    $r = Invoke-Tool 'aspen_reactions' @{ name = 'R-1'; reactions = @($rx) }
    Assert-True (-not $r.isError -and $r.json.reactions -eq 1) 'aspen_reactions creates a POWERLAW set' $r.text
    $r = Invoke-Tool 'aspen_reactions' @{ name = 'R-1'; reactions = @($rx) }
    Assert-True (-not $r.isError) 'calling again replaces the reactions' $r.text
    $r = Invoke-Tool 'aspen_kinetic_reactor' @{ block = 'R2'; reaction_sets = @('R-1'); temperature = 70; pressure = 1.2; volume = 1000; phase = 'L' }
    $vol = @($r.json.settings | Where-Object { $_.path -match '\\VOL$' })[0]
    Assert-True (-not $r.isError -and $vol.units -eq 'l') "RCSTR: reaction set, T, P, volume ($($vol.value) $($vol.units)), liquid phase" $r.text
    $r = Invoke-Tool 'aspen_kinetic_reactor' @{ block = 'R3'; reaction_sets = @('R-1'); temperature = 70; pressure = 1.2; length = 5; diameter = 0.5; phase = 'L' }
    Assert-True (-not $r.isError) 'RPlug: reaction set, constant T, length, diameter' $r.text
    $r = Invoke-Tool 'aspen_kinetic_reactor' @{ block = 'H1'; temperature = 70 }
    Assert-True ($r.isError -and $r.text -match 'RCSTR and RPlug') 'non-reactor blocks are rejected' $r.text

    Write-Host 'calculator'
    $def = @{ FE = @{ type = 'MOLE-FLOW'; stream = 'F3'; component = 'ETOH' }; FA = @{ type = 'MOLE-FLOW'; stream = 'F3'; component = 'ACID' } }
    $r = Invoke-Tool 'aspen_calculator' @{ name = 'C-1'; define = $def; read = @('FE'); write = @('FA'); fortran = "FA = 2.0 * FE"; when = 'BEFORE'; block = 'H1' }
    Assert-True (-not $r.isError) 'aspen_calculator: define, import/export, Fortran, execute before H1' $r.text

    $r = Invoke-Tool 'aspen_run' @{ wait_seconds = 240 } 300
    Assert-True (-not $r.isError -and -not $r.json.running) "run: $($r.json.status)" $r.text
    $r = Invoke-Tool 'aspen_streams' @{ names = @('P1', 'P2', 'P3'); basis = 'mole' }
    $p1 = Get-Stream $r 'P1'; $p2 = Get-Stream $r 'P2'; $p3 = Get-Stream $r 'P3'
    $x1 = (10 - $p1.components.ACID) / 10; $x2 = (10 - $p2.components.ACID) / 10
    Assert-True ($x1 -gt 0.01 -and $x1 -lt 0.99 -and [math]::Abs($p1.components.ETAC - (10 - $p1.components.ACID)) -lt 1e-6) "RCSTR converts $([math]::Round(100 * $x1, 1)) % of ACID; ETAC formed matches" $r.text
    Assert-True ($x2 -gt 0.01 -and $x2 -lt 0.99 -and [math]::Abs($p2.components.WATER - (10 - $p2.components.ACID)) -lt 1e-6) "RPlug converts $([math]::Round(100 * $x2, 1)) % of ACID; WATER formed matches" $r.text
    Assert-True ($x1 -lt $x2) 'CSTR (1 m3) converts less than the plug-flow reactor (0.98 m3), as second-order kinetics require' $r.text
    Assert-True ([math]::Abs($p3.components.ACID - 20) -lt 1e-6) "calculator set F3 ACID = 2 x ETOH: P3 ACID = $($p3.components.ACID)" $r.text
    $r = Invoke-Tool 'aspen_analysis_results' @{ name = 'C-1' }
    $c = @($r.json)[0]
    Assert-True ($c.kind -eq 'calculator' -and [math]::Abs($c.variables.FA.written - 20) -lt 1e-6 -and [math]::Abs($c.variables.FE.read - 10) -lt 1e-6) "calculator results: read FE $($c.variables.FE.read), wrote FA $($c.variables.FA.written) $($c.variables.FA.units)" $r.text
    $r = Invoke-Tool 'aspen_info'
    Assert-True (@($r.json.calculators) -contains 'C-1' -and @($r.json.reaction_sets) -contains 'R-1') 'aspen_info lists calculators and reaction sets' $r.text
    $r = Invoke-Tool 'aspen_delete' @{ kind = 'calculator'; name = 'C-1' }
    Assert-True (-not $r.isError) 'aspen_delete removes the calculator' $r.text
} finally {
    try { [void](Invoke-Tool 'aspen_close' @{} 30) } catch {}
    Stop-McpServer
}
Write-Summary
if ($script:Failed -gt 0) { exit 1 }
