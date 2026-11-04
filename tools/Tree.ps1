# Variable-tree tools: generic read/write access to every Aspen input and result.
# Subtree walks (aspen_tree, aspen_find) run inside the compiled AspCom class; see lib\Com.ps1.

Register-McpTool -Name 'aspen_get' `
    -Description 'Read one or more variable-tree nodes. Returns value, units and child count. Example: \Data\Streams\FEED\Output\TEMP_OUT\MIXED' `
    -Properties @{ path = (P-Str 'Node path'); paths = (P-StrList 'Several node paths') } `
    -Handler {
        param($a)
        $ps = @(); if ($a.path) { $ps += $a.path }; if ($a.paths) { $ps += @($a.paths) }
        if ($ps.Count -eq 0) { throw 'Pass path or paths' }
        if ($ps.Count -eq 1) { return New-JsonResult (Read-AspNode $ps[0]) }
        New-JsonResult ([object[]]($ps | ForEach-Object { Read-AspNode $_ }))
    }

Register-McpTool -Name 'aspen_set' `
    -Description 'Write node values. Either path+value, or values = {path: value, ...}. Numbers are in the node units (see aspen_get); keep strings as strings (e.g. RadFrac BASIS_RR "2", SPEC_OPT "TP"). Returns old and new values.' `
    -Properties @{ path = (P-Str 'Node path'); value = (P-Any 'New value (number or string)'); values = (P-Map 'Map of node path -> value') } `
    -Handler {
        param($a)
        $m = [ordered]@{}
        if ($a.path) { $m[$a.path] = $a.value }
        if ($a.values) { $vm = ConvertTo-Map $a.values; foreach ($k in $vm.Keys) { $m[$k] = $vm[$k] } }
        if ($m.Count -eq 0) { throw 'Pass path+value or values' }
        $out = @()
        foreach ($p in $m.Keys) {
            $n = Find-AspNode $p
            if ($null -eq $n) { $out += [ordered]@{ path = $p; error = 'node not found' }; continue }
            $old = Get-AspValue $n
            try {
                Set-AspValue $n $m[$p]
                $r = [ordered]@{ path = $p; was = $old; now = (Get-AspValue $n) }
                $u = Get-AspUnits $n; if ($u) { $r.units = $u }
                $out += $r
            } catch { $out += [ordered]@{ path = $p; error = (Get-ErrorText $_) } }
        }
        New-JsonResult ([object[]]$out)
    }

Register-McpTool -Name 'aspen_list' `
    -Description 'List the direct children of a node with their values (one level). Start from \Data, \Data\Blocks, \Data\Streams\<S>\Input ...' `
    -Properties @{ path = (P-Str 'Node path'); max = (P-Int 'Maximum children to return (default 300)') } `
    -Required @('path') `
    -Handler {
        param($a)
        $n = Get-AspNode $a.path
        $max = if ($a.max) { [int]$a.max } else { 300 }
        $rows = @(); $i = 0
        foreach ($e in (Get-AspChildren $n)) {
            if ($i++ -ge $max) { $rows += '...(truncated)'; break }
            $r = [ordered]@{ name = (Get-AspName $e) }
            $v = Get-AspValue $e; if ($null -ne $v -and "$v" -ne '') { $r.value = $v }
            $u = Get-AspUnits $e; if ($u) { $r.units = $u }
            $k = Get-AspChildCount $e; if ($k -gt 0) { $r.children = $k }
            $rows += $r
        }
        New-JsonResult ([object[]]$rows)
    }

Register-McpTool -Name 'aspen_tree' `
    -Description 'Dump a subtree as "path = value [units]" lines, recursing up to depth levels. By default only non-empty leaves are shown, which makes it the quickest way to see what is specified on a block or stream (e.g. \Data\Blocks\H1\Input).' `
    -Properties @{ path = (P-Str 'Root node'); depth = (P-Int 'Levels to descend (default 3)'); include_empty = (P-Bool 'Also show empty leaves'); max_lines = (P-Int 'Default 400') } `
    -Required @('path') `
    -Handler {
        param($a)
        $n = Get-AspNode $a.path
        $d = if ($a.depth) { [int]$a.depth } else { 3 }
        $lim = if ($a.max_lines) { [int]$a.max_lines } else { 400 }
        New-TextResult ([AspCom]::Tree($n, $a.path.TrimEnd('\'), $d, (-not [bool]$a.include_empty), $lim))
    }

Register-McpTool -Name 'aspen_find' `
    -Description 'Search node names (regex, case-insensitive) below a root, breadth-first. Useful to locate keys like QCALC, VFRAC or REB_DUTY.' `
    -Properties @{ root = (P-Str 'Where to search, e.g. \Data\Blocks\C1'); pattern = (P-Str 'Regex for node names'); depth = (P-Int 'Max depth (default 4)'); max = (P-Int 'Max hits (default 50)') } `
    -Required @('root', 'pattern') `
    -Handler {
        param($a)
        $maxD = if ($a.depth) { [int]$a.depth } else { 4 }
        $max = if ($a.max) { [int]$a.max } else { 50 }
        $root = Get-AspNode $a.root
        $visited = 0
        $found = [AspCom]::Search($root, $a.root.TrimEnd('\'), $a.pattern, $maxD, $max, 200000, 25000, [ref]$visited)
        $hits = @()
        foreach ($h in $found) {
            $r = [ordered]@{ path = $h[0] }
            if ($h[1] -ne '') { $r.value = ConvertTo-AspOutput $h[1] }
            if ($h[2]) { $r.units = $h[2] }
            $hits += $r
        }
        New-JsonResult ([ordered]@{ hits = [object[]]$hits; nodes_scanned = $visited })
    }

Register-McpTool -Name 'aspen_add_row' `
    -Description 'Add a labelled row to a table-style node: component list (\Data\Components\Specifications\Input\TYPE), heater curve keys (...\Input\INDEP_VAR), etc. Then set the new cells with aspen_set.' `
    -Properties @{ path = (P-Str 'Table node'); label = (P-Str 'Row label') } `
    -Required @('path', 'label') `
    -Handler {
        param($a)
        $rn = Add-AspRow $a.path $a.label
        New-TextResult "Added row '$($a.label)' at index $rn under $($a.path)"
    }
