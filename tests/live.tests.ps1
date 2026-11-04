# End-to-end test against a real Aspen Plus V14 (opens visible Aspen windows, ~1-2 minutes).
#   powershell -ExecutionPolicy Bypass -File tests\live.tests.ps1 [-ProtectedFile <a .bkp inside a protected folder>]
# -ProtectedFile (or $env:ASPEN_MCP_PROTECTED_FILE) must lie in one of config.json's protected_paths;
# the protection tests are skipped without it.
param([string]$ProtectedFile = $env:ASPEN_MCP_PROTECTED_FILE)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'McpClient.ps1')

$started = Get-Date
[void](Start-McpServer (Join-Path $root 'server.ps1'))
try {
    [void](Invoke-Mcp 'initialize' @{ protocolVersion = '2025-06-18' })

    Write-Host 'build a flowsheet from scratch'
    $r = Invoke-Tool 'aspen_new' @{ unit_set = 'METCBAR' }
    Assert-True (-not $r.isError -and $r.json.unit_set -eq 'METCBAR') 'aspen_new opens a blank METCBAR simulation' $r.text
    $r = Invoke-Tool 'aspen_new' @{}
    Assert-True ($r.isError -and $r.text -match 'replace=true') 'a second aspen_new without replace is refused' $r.text

    $r = Invoke-Tool 'aspen_add_components' @{ components = @('WATER', 'MEOH=METHANOL', 'ZZQX=NOT-A-REAL-COMPOUND') }
    $c = @($r.json.components)
    Assert-True ($c[0].found -and $c[0].formula -eq 'H2O') 'WATER found in the databank (H2O)' $r.text
    Assert-True ($c[1].found -and $c[1].id -eq 'MEOH') 'MEOH=METHANOL found' $r.text
    Assert-True (-not $c[2].found) 'a bogus compound is reported as not found' $r.text
    $r = Invoke-Tool 'aspen_remove_component' @{ id = 'ZZQX' }
    Assert-True (-not $r.isError) 'aspen_remove_component' $r.text
    $r = Invoke-Tool 'aspen_set_property_method' @{ method = 'nrtl' }
    Assert-True ($r.json.property_method -eq 'NRTL') 'property method NRTL' $r.text

    foreach ($s in @(@{ name = 'FEED' }, @{ name = 'OUT' }, @{ name = 'Q1'; type = 'HEAT' })) {
        $r = Invoke-Tool 'aspen_add_stream' $s
        Assert-True (-not $r.isError) "add stream $($s.name)" $r.text
    }
    $r = Invoke-Tool 'aspen_add_block' @{ name = 'H1'; model = 'Heater' }
    Assert-True (-not $r.isError -and $r.json.model -eq 'Heater' -and @($r.json.ports) -contains 'F(IN)') 'add Heater H1 (lists its ports)' $r.text
    foreach ($cn in @(@('F(IN)', 'FEED'), @('P(OUT)', 'OUT'), @('HS(OUT)', 'Q1'))) {
        $r = Invoke-Tool 'aspen_connect' @{ block = 'H1'; port = $cn[0]; stream = $cn[1] }
        Assert-True (-not $r.isError) "connect $($cn[1]) to H1.$($cn[0])" $r.text
    }
    $r = Invoke-Tool 'aspen_connect' @{ block = 'H1'; port = 'X(IN)'; stream = 'FEED' }
    Assert-True ($r.isError -and $r.text -match 'Available: .*F\(IN\)') 'bad port name lists the available ports' $r.text

    $r = Invoke-Tool 'aspen_set_stream' @{ name = 'FEED'; temperature = 25; pressure = 1.5; flow_basis = 'MOLE'; component_flows = @{ WATER = 80; MEOH = 20.5 } }
    $bad = @($r.json | Where-Object { $_.error })
    Assert-True (-not $r.isError -and $bad.Count -eq 0) 'aspen_set_stream sets T, P, basis and flows' $r.text
    $t = @($r.json | Where-Object { $_.path -match 'TEMP' })[0]
    Assert-True ($t.units -eq 'C') "stream temperature is in C ($($t.units))" $r.text
    $r = Invoke-Tool 'aspen_set' @{ values = @{ '\Data\Blocks\H1\Input\SPEC_OPT' = 'TP'; '\Data\Blocks\H1\Input\TEMP' = 60; '\Data\Blocks\H1\Input\PRES' = 1.2 } }
    Assert-True (-not $r.isError -and @($r.json | Where-Object { $_.error }).Count -eq 0) 'aspen_set (batch) sets heater specs' $r.text
    $r = Invoke-Tool 'aspen_set' @{ path = '\Data\Blocks\H1\Input\NOPE'; value = 1 }
    Assert-True (@($r.json)[0].error -eq 'node not found') 'setting a missing node reports node not found' $r.text

    $r = Invoke-Tool 'aspen_flowsheet'
    $q = @($r.json.streams | Where-Object { $_.name -eq 'Q1' })[0]
    $o = @($r.json.streams | Where-Object { $_.name -eq 'OUT' })[0]
    Assert-True ($q.type -eq 'HEAT' -and $q.from -eq 'H1.HS(OUT)') 'topology: Q1 is a HEAT stream from H1.HS(OUT)' $r.text
    Assert-True ($o.from -eq 'H1.P(OUT)' -and $null -eq $o.to) 'topology: OUT leaves H1.P(OUT) as a product' $r.text

    Write-Host 'run and read results'
    $r = Invoke-Tool 'aspen_run' @{ wait_seconds = 90 } 150
    Assert-True (-not $r.isError -and -not $r.json.running) 'aspen_run completes' $r.text
    Assert-True ($r.json.status -match 'completed normally' -or $r.json.codes.PER_ERROR -eq 0) "run status: $($r.json.status)" $r.text
    $r = Invoke-Tool 'aspen_streams' @{ basis = 'mole' }
    $out = @($r.json.streams | Where-Object { $_.stream -eq 'OUT' })[0]
    $feed = @($r.json.streams | Where-Object { $_.stream -eq 'FEED' })[0]
    Assert-True ([math]::Abs($out.T - 60) -lt 0.01) "OUT temperature = $($out.T) $($r.json.units.T)" $r.text
    Assert-True ([math]::Abs($out.components.MEOH - 20.5) -lt 1e-6 -and [math]::Abs($out.components.WATER - 80) -lt 1e-6) 'component flows are conserved (mole basis)' $r.text
    Assert-True ([math]::Abs($feed.mass_flow - $out.mass_flow) -lt 1e-6 -and $out.mass_flow -gt 2000) "mass balance closes ($($out.mass_flow) $($r.json.units.mass_flow))" $r.text
    $q1 = @($r.json.streams | Where-Object { $_.stream -eq 'Q1' })[0]
    $r = Invoke-Tool 'aspen_block_results' @{ block = 'H1' }
    Assert-True (-not $r.isError -and "$($r.json.results.QCALC)" -match '\[') "block results with units: QCALC = $($r.json.results.QCALC)" $r.text
    $qcalc = [double](("$($r.json.results.QCALC)" -split ' ')[0])
    Assert-True ($qcalc -gt 0 -and [math]::Abs([math]::Abs($q1.duty) - $qcalc) -lt 1e-6) "heat stream Q1 carries the heater duty ($($q1.duty), Aspen sign convention)" $r.text
    $r = Invoke-Tool 'aspen_get' @{ paths = @('\Data\Blocks\H1\Output\QCALC', '\Data\Streams\OUT\Output\TEMP_OUT\MIXED') }
    Assert-True (@($r.json).Count -eq 2 -and @($r.json)[1].units -eq 'C') 'aspen_get with several paths returns units' $r.text
    $r = Invoke-Tool 'aspen_tree' @{ path = '\Data\Blocks\H1\Input'; depth = 1 }
    Assert-True ($r.text -match 'SPEC_OPT = TP' -and $r.text -match 'TEMP = 60 \[C\]') 'aspen_tree shows the specified inputs with units' $r.text
    $r = Invoke-Tool 'aspen_find' @{ root = '\Data\Streams\OUT\Output'; pattern = '^VFRAC'; depth = 2 }
    Assert-True (@($r.json.hits).Count -gt 0) "aspen_find locates VFRAC nodes ($(@($r.json.hits).Count))" $r.text
    $r = Invoke-Tool 'aspen_list' @{ path = '\Data\Blocks' }
    Assert-True (@($r.json)[0].name -eq 'H1') 'aspen_list' $r.text
    $r = Invoke-Tool 'aspen_report' @{ pattern = 'BLOCK:\s+H1'; context = 4 }
    Assert-True (-not $r.isError -and $r.text -match 'H1') 'aspen_report finds the H1 block section' $r.text
    $r = Invoke-Tool 'aspen_status'
    Assert-True (-not $r.json.running -and $r.json.codes.PER_ERROR -eq 0) 'aspen_status after the run' $r.text

    Write-Host 'see it live'
    $resp = Invoke-Mcp 'tools/call' @{ name = 'aspen_screenshot'; arguments = @{ max_width = 1200 } } 60
    $img = @($resp.result.content | Where-Object { $_.type -eq 'image' })[0]
    Assert-True ($img -and $img.mimeType -eq 'image/png' -and $img.data.Length -gt 5000) "screenshot returns a PNG ($([int]($img.data.Length * 3 / 4 / 1KB)) KB)" ($resp | ConvertTo-Json -Depth 3)

    Write-Host 'save'
    $r = Invoke-Tool 'aspen_save' @{}
    Assert-True ($r.isError -and $r.text -match 'no file yet') 'saving a new simulation needs a file name' $r.text
    $r = Invoke-Tool 'aspen_save' @{ file = 'live_test.bkp'; overwrite = $true }
    Assert-True (-not $r.isError -and (Test-Path $r.json.saved)) "saved $($r.json.saved)" $r.text
    $r = Invoke-Tool 'aspen_info'
    Assert-True ($r.json.working_file -match 'live_test\.bkp$' -and @($r.json.blocks) -contains 'H1') 'aspen_info tracks the working file' $r.text

    if ($ProtectedFile -and (Test-Path $ProtectedFile)) {
        Write-Host 'protected folders'
        $protDir = Split-Path $ProtectedFile -Parent
        $r = Invoke-Tool 'aspen_open' @{ file = $ProtectedFile; in_place = $true; replace = $true }
        Assert-True ($r.isError -and $r.text -match 'protected') 'in_place open of a protected file is refused' $r.text
        $r = Invoke-Tool 'aspen_open' @{ file = $ProtectedFile; replace = $true } 240
        Assert-True (-not $r.isError -and $r.json.protected_source -and $r.json.working_file -notlike "$protDir*") 'protected file opens as a workspace copy' $r.text
        Assert-True (@($r.json.blocks).Count -gt 0) "opened project file has $(@($r.json.blocks).Count) blocks" $r.text
        $r = Invoke-Tool 'aspen_streams' @{}
        Assert-True (-not $r.isError -and @($r.json.streams).Count -gt 0) "reads $(@($r.json.streams).Count) streams from the copy" $r.text
        $r = Invoke-Tool 'aspen_save' @{ file = (Join-Path $protDir 'should_not_exist.bkp') }
        Assert-True ($r.isError -and $r.text -match 'protected') 'saving into the protected folder is refused' $r.text
        $r = Invoke-Tool 'aspen_report' @{ pattern = 'x'; save_to = (Join-Path $protDir 'x.rep') }
        Assert-True ($r.isError -or $r.text -match 'No report') 'report export into the protected folder is refused' $r.text
        $changed = @(Get-ChildItem (Split-Path $protDir -Parent) -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $started })
        Assert-True ($changed.Count -eq 0) 'nothing in the protected project was modified' ($changed | ForEach-Object FullName)
    }

    $r = Invoke-Tool 'aspen_close'
    Assert-True (-not $r.isError) 'aspen_close quits Aspen' $r.text
    $r = Invoke-Tool 'aspen_info'
    Assert-True ($r.json.open -eq $false) 'no session after close' $r.text
} finally {
    try { [void](Invoke-Tool 'aspen_close' @{} 30) } catch {}
    Stop-McpServer
}
Write-Summary
if ($script:Failed -gt 0) { exit 1 }
