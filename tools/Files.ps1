# Read-only file access for simulation files and their text outputs. No Aspen session needed.

$script:AspenExt = @('.apw', '.apwz', '.bkp', '.inp', '.rep', '.sum', '.csv', '.txt', '.md')
$script:BinaryExt = @('.apw', '.apwz', '.his', '.scr', '.rp1', '.rp2', '.ads', '.appdf', '.exe', '.dll', '.zip', '.pdf', '.docx', '.xlsx', '.png', '.jpg', '.jpeg')

Register-McpTool -Name 'aspen_list_files' `
    -Description 'List simulation-related files (.apw .apwz .bkp .inp .rep .sum .csv .txt .md) in a folder, newest first. Read-only.' `
    -Properties @{ dir = (P-Str 'Folder'); filter = (P-Str 'Regex on the full path'); recurse = (P-Bool 'Search subfolders (default true)'); max = (P-Int 'Default 200') } `
    -Required @('dir') `
    -Handler {
        param($a)
        $dir = Resolve-AspPath $a.dir
        if (-not (Test-Path -LiteralPath $dir)) { throw "Folder not found: $dir" }
        $gc = @{ LiteralPath = $dir; File = $true; ErrorAction = 'SilentlyContinue' }
        if ($a.recurse -ne $false) { $gc.Recurse = $true }
        $files = Get-ChildItem @gc | Where-Object { $script:AspenExt -contains $_.Extension.ToLower() }
        if ($a.filter) { $files = $files | Where-Object { $_.FullName -match $a.filter } }
        $max = if ($a.max) { [int]$a.max } else { 200 }
        $rows = @($files | Sort-Object LastWriteTime -Descending | Select-Object -First $max | ForEach-Object {
                [ordered]@{ path = $_.FullName; kb = [int][math]::Ceiling($_.Length / 1KB); modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } })
        New-JsonResult ([object[]]$rows)
    }

Register-McpTool -Name 'aspen_read_file' `
    -Description 'Read a text file (.bkp, .inp, .rep, .sum, .csv, .txt, .md, scripts). Binary files (.apw, .apwz, .his) are refused: open those with aspen_open. pattern (regex) + context searches large files; head/tail slice them. Read-only.' `
    -Properties @{ path = (P-Str 'File path'); pattern = (P-Str 'Regex'); context = (P-Int 'Context lines (default 2)'); head = (P-Int 'First N lines (default 200)'); tail = (P-Int 'Last N lines'); max_chars = (P-Int 'Default 40000') } `
    -Required @('path') `
    -Handler {
        param($a)
        $p = Resolve-AspPath $a.path
        if (-not (Test-Path -LiteralPath $p)) { throw "File not found: $p" }
        $ext = [IO.Path]::GetExtension($p).ToLower()
        if ($script:BinaryExt -contains $ext) { throw "$ext is a binary file. Open it with aspen_open instead." }
        $maxc = if ($a.max_chars) { [int]$a.max_chars } else { 40000 }
        if ($a.pattern) {
            $ctx = if ($null -ne $a.context) { [int]$a.context } else { 2 }
            $m = Select-String -LiteralPath $p -Pattern $a.pattern -Context $ctx | Select-Object -First 60
            $txt = ($m | ForEach-Object { "[line $($_.LineNumber)]`n" + (($_.Context.PreContext + $_.Line + $_.Context.PostContext) -join "`n") }) -join "`n--`n"
            if (-not $txt) { $txt = "No lines match '$($a.pattern)'." }
        } elseif ($a.tail) {
            $txt = (Get-Content -LiteralPath $p -Tail ([int]$a.tail)) -join "`n"
        } else {
            $h = if ($a.head) { [int]$a.head } else { 200 }
            $txt = (Get-Content -LiteralPath $p -TotalCount $h) -join "`n"
        }
        if ($txt.Length -gt $maxc) { $txt = $txt.Substring(0, $maxc) + "`n...(truncated)" }
        New-TextResult $txt
    }
