# Results: stream tables and block outputs.

function Read-AspWithUnits([string]$path, $units, [string]$key) {
    $n = Find-AspNode $path
    if ($null -eq $n) { return $null }
    if ($units -and -not $units.Contains($key)) { $u = Get-AspUnits $n; if ($u) { $units[$key] = $u } }
    return (ConvertTo-Double (Get-AspValue $n))
}

Register-McpTool -Name 'aspen_streams' `
    -Description 'Stream results table: T, P, vapour fraction, total mass and mole flow, and non-zero component flows (basis mass or mole). Heat streams report their duty. Omit names for all streams. Units are listed once.' `
    -Properties @{ names = (P-StrList 'Stream names (default all)'); basis = (P-Enum 'Component flow basis' @('mass', 'mole')); include_zero = (P-Bool 'Keep zero component flows') } `
    -Handler {
        param($a)
        $names = if ($a.names) { @($a.names) } else { Get-AspChildNames '\Data\Streams' }
        $basis = if ($a.basis -eq 'mole') { 'MOLEFLOW' } else { 'MASSFLOW' }
        $units = [ordered]@{}
        $rows = @()
        foreach ($s in $names) {
            $sn = Find-AspNode "\Data\Streams\$s"
            if ($null -eq $sn) { $rows += [ordered]@{ stream = $s; error = 'not found' }; continue }
            $type = Get-AspAttr $sn 6
            $o = "\Data\Streams\$s\Output"
            $r = [ordered]@{ stream = $s; type = $type }
            if ($type -eq 'HEAT') {
                $r.duty = Read-AspWithUnits "$o\QCALC" $units 'duty'
            } elseif ($type -eq 'WORK') {
                $r.power = Read-AspWithUnits "$o\POWER_OUT" $units 'power'
            } else {
                $r.T = Read-AspWithUnits "$o\TEMP_OUT\MIXED" $units 'T'
                $r.P = Read-AspWithUnits "$o\PRES_OUT\MIXED" $units 'P'
                $r.vfrac = Read-AspWithUnits "$o\VFRAC_OUT\MIXED" $null 'vfrac'
                $r.mass_flow = Read-AspWithUnits "$o\MASSFLMX\MIXED" $units 'mass_flow'
                $r.mole_flow = Read-AspWithUnits "$o\MOLEFLMX\MIXED" $units 'mole_flow'
                $comp = [ordered]@{}
                $cn = Find-AspNode "$o\$basis\MIXED"
                if ($null -ne $cn) {
                    foreach ($e in (Get-AspChildren $cn)) {
                        $v = ConvertTo-Double (Get-AspValue $e)
                        if ($null -eq $v) { continue }
                        if ($v -ne 0 -or $a.include_zero) { $comp[(Get-AspName $e)] = [math]::Round($v, 6) }
                        if (-not $units.Contains('components')) { $u = Get-AspUnits $e; if ($u) { $units['components'] = $u } }
                    }
                }
                $r.components = $comp
                if ($null -eq $r.T -and $null -eq $r.mass_flow) { $r.note = 'no results (not run yet?)' }
            }
            $rows += $r
        }
        New-JsonResult ([ordered]@{ units = $units; component_basis = $basis.Replace('FLOW', '').ToLower(); streams = [object[]]$rows })
    }

Register-McpTool -Name 'aspen_block_results' `
    -Description 'Scalar results of a block (everything non-empty directly under \Data\Blocks\<name>\Output, with units), e.g. duties, temperatures, reflux ratio. Vector results (stage profiles) are listed by name; read them with aspen_list or aspen_tree. filter is an optional regex on result names.' `
    -Properties @{ block = (P-Str 'Block name'); filter = (P-Str 'Regex on result names') } `
    -Required @('block') `
    -Handler {
        param($a)
        $bn = Get-AspNode "\Data\Blocks\$($a.block)"
        $out = Get-AspNode "\Data\Blocks\$($a.block)\Output"
        $scalars = [ordered]@{}; $vectors = [ordered]@{}
        foreach ($e in (Get-AspChildren $out)) {
            $nm = Get-AspName $e
            if ($a.filter -and $nm -notmatch $a.filter) { continue }
            $k = (Get-AspChildren $e).Count
            if ($k -gt 0) { $vectors[$nm] = $k; continue }
            $v = Get-AspValue $e
            if ($null -eq $v -or "$v" -eq '') { continue }
            $u = Get-AspUnits $e
            $scalars[$nm] = if ($u) { "$v [$u]" } else { $v }
        }
        New-JsonResult ([ordered]@{ block = $a.block; model = (Get-AspAttr $bn 6); results = $scalars; vector_results = $vectors })
    }
