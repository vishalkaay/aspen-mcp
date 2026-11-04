# Running the solver. Engine.Run2 returns immediately, so runs are started, then polled.

Register-McpTool -Name 'aspen_run' `
    -Description 'Run the simulation. Waits up to wait_seconds (default from config, 40) and returns status, run codes and problem messages. If running=true comes back, poll aspen_status. reinit=true clears previous results first (cold start).' `
    -Properties @{ reinit = (P-Bool 'Reinitialize before running'); wait_seconds = (P-Int 'How long to wait for completion') } `
    -Handler {
        param($a)
        $app = Get-AspApp
        $eng = Get-ComProp $app 'Engine'
        if ([bool](Get-ComProp $eng 'IsRunning')) { throw 'A run is already in progress; use aspen_status or aspen_stop.' }
        if ($a.reinit) { [void](Invoke-ComMethod $app 'Reinit') }
        $wait = if ($a.wait_seconds) { [int]$a.wait_seconds } else { [int]$global:S.Config.run_wait_seconds }
        $global:S.RunStart = Get-Date
        [void](Invoke-ComMethod $eng 'Run2')
        Start-Sleep -Seconds 2
        # IsRunning can read false for a moment after Run2, so require two quiet polls.
        $quiet = 0
        while ($quiet -lt 2 -and ((Get-Date) - $global:S.RunStart).TotalSeconds -lt $wait) {
            if ([bool](Get-ComProp $eng 'IsRunning')) { $quiet = 0 } else { $quiet++ }
            Start-Sleep -Milliseconds 700
        }
        New-JsonResult (Get-RunState)
    }

Register-McpTool -Name 'aspen_status' `
    -Description 'Is the solver running? Elapsed time, run codes (PER_ERROR: 0 = no errors), and when finished the report STATUS line plus problem messages (errors/warnings per block).' `
    -Handler { param($a) New-JsonResult (Get-RunState) }

Register-McpTool -Name 'aspen_stop' `
    -Description 'Stop a running simulation.' `
    -Handler {
        param($a)
        [void](Invoke-ComMethod (Get-ComProp (Get-AspApp) 'Engine') 'Stop')
        New-TextResult 'Stop requested.'
    }

Register-McpTool -Name 'aspen_reinit' `
    -Description 'Reinitialize: discard results and convergence estimates (next run is a cold start).' `
    -Handler { param($a) [void](Invoke-ComMethod (Get-AspApp) 'Reinit'); New-TextResult 'Reinitialized.' }

Register-McpTool -Name 'aspen_report' `
    -Description 'Export the full Aspen text report (.rep) of the current results. pattern (regex) returns matching lines with context; otherwise the first max_lines lines. section="BLOCK: C1" style patterns work well. save_to copies the full report to a path (not into protected folders).' `
    -Properties @{ pattern = (P-Str 'Regex to search'); context = (P-Int 'Lines of context (default 3)'); max_lines = (P-Int 'Lines when no pattern (default 150)'); save_to = (P-Str 'Optional path to keep the report') } `
    -Handler {
        param($a)
        $rep = Export-AspReport
        if (-not $rep) { return New-TextResult 'No report available yet: run the simulation first.' }
        try {
            $note = ''
            if ($a.save_to) {
                $dest = Resolve-AspPath $a.save_to
                if (Test-ProtectedPath $dest) { throw "Refusing to write into a protected folder: $dest" }
                Copy-Item -LiteralPath $rep -Destination $dest -Force
                $note = "Saved full report to $dest`n"
            }
            if ($a.pattern) {
                $ctx = if ($null -ne $a.context) { [int]$a.context } else { 3 }
                $m = Select-String -LiteralPath $rep -Pattern $a.pattern -Context $ctx | Select-Object -First 40
                $txt = ($m | ForEach-Object { "[line $($_.LineNumber)]`n" + (($_.Context.PreContext + $_.Line + $_.Context.PostContext) -join "`n") }) -join "`n--`n"
                if (-not $txt) { $txt = "No lines match '$($a.pattern)'." }
            } else {
                $max = if ($a.max_lines) { [int]$a.max_lines } else { 150 }
                $txt = (Get-Content -LiteralPath $rep -TotalCount $max) -join "`n"
            }
            if ($txt.Length -gt 60000) { $txt = $txt.Substring(0, 60000) + "`n...(truncated)" }
            New-TextResult ($note + $txt)
        } finally { Remove-Item -LiteralPath $rep -Force -ErrorAction SilentlyContinue }
    }
