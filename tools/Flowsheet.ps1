# Flowsheet building: components, property method, units, blocks, streams, connections, stream specs.

$script:CompTable = '\Data\Components\Specifications\Input'

function Get-AspTopology([bool]$allPorts) {
    $blocks = @(); $from = @{}; $to = @{}
    foreach ($b in (Get-AspChildren (Get-AspNode '\Data\Blocks'))) {
        $bn = Get-AspName $b
        $ports = [ordered]@{}
        $pn = Find-AspNode "\Data\Blocks\$bn\Ports"
        if ($null -ne $pn) {
            foreach ($p in (Get-AspChildren $pn)) {
                $port = Get-AspName $p
                $ss = @(); foreach ($s in (Get-AspChildren $p)) { $ss += (Get-AspName $s) }
                if ($ss.Count -gt 0 -or $allPorts) { $ports[$port] = [object[]]$ss }
                foreach ($s in $ss) { if ($port -match '\(OUT\)') { $from[$s] = "$bn.$port" } else { $to[$s] = "$bn.$port" } }
            }
        }
        $blocks += [ordered]@{ name = $bn; model = (Get-AspAttr $b 6); ports = $ports }
    }
    $streams = @()
    foreach ($s in (Get-AspChildren (Get-AspNode '\Data\Streams'))) {
        $sn = Get-AspName $s
        $streams += [ordered]@{ name = $sn; type = (Get-AspAttr $s 6); from = $from[$sn]; to = $to[$sn] }
    }
    [ordered]@{ blocks = [object[]]$blocks; streams = [object[]]$streams }
}

Register-McpTool -Name 'aspen_flowsheet' `
    -Description 'Flowsheet topology as data: every block with its model (RadFrac, Heater, RCSTR ...) and connected ports, every stream with its type and from/to block.port (null = feed or product).' `
    -Properties @{ all_ports = (P-Bool 'Also list unconnected ports (to see what a block accepts)') } `
    -Handler { param($a) New-JsonResult (Get-AspTopology ([bool]$a.all_ports)) }

Register-McpTool -Name 'aspen_add_components' `
    -Description 'Add conventional components from the databank. Each entry is "ID" (looked up by that name) or "ID=DATABANK-NAME", e.g. ["WATER", "MEOH=METHANOL", "AA=ACETIC-ACID"]. Reports whether Aspen found each one (formula filled in).' `
    -Properties @{ components = (P-StrList 'Component entries') } `
    -Required @('components') `
    -Handler {
        param($a)
        $out = @()
        foreach ($entry in @($a.components)) {
            $id, $db = ([string]$entry).Split('=', 2)
            $id = $id.Trim().ToUpper(); $db = if ($db) { $db.Trim().ToUpper() } else { $id }
            $r = [ordered]@{ id = $id; databank_name = $db }
            if ($null -eq (Find-AspNode "$script:CompTable\TYPE\$id")) { [void](Add-AspRow "$script:CompTable\TYPE" $id) } else { $r.note = 'already present' }
            Set-AspValue (Get-AspNode "$script:CompTable\TYPE\$id") 'CONV'
            Set-AspValue (Get-AspNode "$script:CompTable\DBNAME1\$id") $db
            $r.formula = Get-AspValue (Find-AspNode "$script:CompTable\ANAME\$id")
            $r.found = ("$($r.formula)" -ne '')
            $out += $r
        }
        New-JsonResult ([object[]]$out)
    }

Register-McpTool -Name 'aspen_remove_component' `
    -Description 'Remove a component by ID.' `
    -Properties @{ id = (P-Str 'Component ID') } -Required @('id') `
    -Handler { param($a) Remove-AspRow "$script:CompTable\TYPE" $a.id.ToUpper(); New-TextResult "Removed $($a.id)" }

Register-McpTool -Name 'aspen_set_property_method' `
    -Description 'Set the global property method, e.g. NRTL, UNIQUAC, WILSON, PENG-ROB, RK-SOAVE, SRK, IDEAL, STEAM-TA, WILS-HOC, ELECNRTL.' `
    -Properties @{ method = (P-Str 'Property method name') } -Required @('method') `
    -Handler {
        param($a)
        $n = Get-AspNode '\Data\Properties\Specifications\Input\GBASEOPSET'
        Set-AspValue $n $a.method.ToUpper()
        New-JsonResult ([ordered]@{ property_method = (Get-AspValue $n) })
    }

Register-McpTool -Name 'aspen_set_units' `
    -Description 'Set the global unit set for input and results: METCBAR (C, bar, kmol/hr), MET, SI, ENG, or any set listed under \Data\Setup\Units-Sets. Values already entered keep their physical meaning; numbers you enter afterwards are read in the new units.' `
    -Properties @{ unit_set = (P-Str 'Unit set name, e.g. METCBAR') } -Required @('unit_set') `
    -Handler { param($a) New-JsonResult (Set-AspUnitSet $a.unit_set) }

Register-McpTool -Name 'aspen_add_block' `
    -Description 'Add a unit operation block. model is the Aspen model name: Mixer, FSplit, SSplit, Flash2, Flash3, Decanter, Sep, Sep2, Heater, HeatX, MHeatX, DSTWU, Distl, RadFrac, Extract, RStoic, RYield, REquil, RGibbs, RCSTR, RPlug, RBatch, Pump, Compr, MCompr, Valve, Pipe, ... Optional icon e.g. "ICON1".' `
    -Properties @{ name = (P-Str 'Block name'); model = (P-Str 'Aspen model'); icon = (P-Str 'Optional icon id') } `
    -Required @('name', 'model') `
    -Handler {
        param($a)
        $spec = "$($a.name)!$($a.model.ToUpper())"; if ($a.icon) { $spec += "!$($a.icon)" }
        Add-AspElement '\Data\Blocks' $spec
        $b = Get-AspNode "\Data\Blocks\$($a.name)"
        $ports = @(); foreach ($p in (Get-AspChildren (Get-AspNode "\Data\Blocks\$($a.name)\Ports"))) { $ports += (Get-AspName $p) }
        New-JsonResult ([ordered]@{ added = $a.name; model = (Get-AspAttr $b 6); ports = [object[]]$ports })
    }

Register-McpTool -Name 'aspen_add_stream' `
    -Description 'Add a stream. type MATERIAL (default), HEAT or WORK.' `
    -Properties @{ name = (P-Str 'Stream name'); type = (P-Enum 'Stream type' @('MATERIAL', 'HEAT', 'WORK')) } `
    -Required @('name') `
    -Handler {
        param($a)
        $spec = $a.name; if ($a.type -and $a.type -ne 'MATERIAL') { $spec += "!$($a.type)" }
        Add-AspElement '\Data\Streams' $spec
        New-JsonResult ([ordered]@{ added = $a.name; type = (Get-AspAttr (Get-AspNode "\Data\Streams\$($a.name)") 6) })
    }

Register-McpTool -Name 'aspen_connect' `
    -Description 'Connect a stream to a block port. Material ports: F(IN) feed, P(OUT) product (Flash2: V(OUT), L(OUT); RadFrac: VD(OUT), LD(OUT), B(OUT)). Heat ports: HS(IN)/HS(OUT); work: WS(IN)/WS(OUT). aspen_flowsheet with all_ports=true lists them.' `
    -Properties @{ block = (P-Str 'Block name'); port = (P-Str 'Port, e.g. F(IN)'); stream = (P-Str 'Stream name') } `
    -Required @('block', 'port', 'stream') `
    -Handler {
        param($a)
        $pp = "\Data\Blocks\$($a.block)\Ports\$($a.port)"
        if ($null -eq (Find-AspNode $pp)) {
            $avail = Get-AspChildNames "\Data\Blocks\$($a.block)\Ports"
            throw "Port $($a.port) not found on $($a.block). Available: $($avail -join ', ')"
        }
        Add-AspElement $pp $a.stream
        New-TextResult "Connected $($a.stream) -> $($a.block).$($a.port)"
    }

Register-McpTool -Name 'aspen_disconnect' `
    -Description 'Disconnect a stream from a block port.' `
    -Properties @{ block = (P-Str 'Block name'); port = (P-Str 'Port'); stream = (P-Str 'Stream name') } `
    -Required @('block', 'port', 'stream') `
    -Handler {
        param($a)
        Remove-AspElement "\Data\Blocks\$($a.block)\Ports\$($a.port)" $a.stream
        New-TextResult "Disconnected $($a.stream) from $($a.block).$($a.port)"
    }

Register-McpTool -Name 'aspen_delete' `
    -Description 'Delete a block or a stream.' `
    -Properties @{ kind = (P-Enum 'What to delete' @('block', 'stream')); name = (P-Str 'Name') } `
    -Required @('kind', 'name') `
    -Handler {
        param($a)
        $root = if ($a.kind -eq 'block') { '\Data\Blocks' } else { '\Data\Streams' }
        Remove-AspElement $root $a.name
        New-TextResult "Deleted $($a.kind) $($a.name)"
    }

Register-McpTool -Name 'aspen_set_stream' `
    -Description 'Specify a feed stream: temperature and pressure plus component flows, in the simulation units (aspen_info shows the unit set). flow_basis MOLE (default), MASS or STDVOL. Components must already exist.' `
    -Properties @{
        name = (P-Str 'Stream name'); temperature = (P-Num 'Temperature'); pressure = (P-Num 'Pressure')
        flow_basis = (P-Enum 'Basis for component_flows' @('MOLE', 'MASS', 'STDVOL'))
        component_flows = (P-Map 'Map of component ID -> flow, e.g. {"WATER": 100}')
    } `
    -Required @('name') `
    -Handler {
        param($a)
        $base = "\Data\Streams\$($a.name)\Input"
        [void](Get-AspNode $base)
        $set = [ordered]@{}
        if ($null -ne $a.temperature) { $set["$base\TEMP\MIXED"] = $a.temperature }
        if ($null -ne $a.pressure) { $set["$base\PRES\MIXED"] = $a.pressure }
        if ($a.flow_basis) { $set["$base\FLOWBASE\MIXED"] = $a.flow_basis }
        $flows = ConvertTo-Map $a.component_flows
        foreach ($c in $flows.Keys) { $set["$base\FLOW\MIXED\$($c.ToUpper())"] = $flows[$c] }
        $out = @()
        foreach ($p in $set.Keys) {
            $n = Find-AspNode $p
            if ($null -eq $n) { $out += [ordered]@{ path = $p; error = 'node not found (is the component defined?)' }; continue }
            try {
                Set-AspValue $n $set[$p]
                $r = [ordered]@{ path = $p; value = (Get-AspValue $n) }
                $u = Get-AspUnits $n; if ($u) { $r.units = $u }
                $out += $r
            } catch { $out += [ordered]@{ path = $p; error = (Get-ErrorText $_) } }
        }
        New-JsonResult ([object[]]$out)
    }
