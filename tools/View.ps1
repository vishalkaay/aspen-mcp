# Screenshot of the live Aspen window (PrintWindow works even when the window is covered).

$script:WinCapLoaded = $false
function Initialize-WinCap {
    if ($script:WinCapLoaded) { return }
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
public static class AspenWinCap {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    public static void Restore(IntPtr h) { if (IsIconic(h)) ShowWindow(h, 9); }
    public static void Maximize(IntPtr h) { ShowWindow(h, 3); }
    public static byte[] CapturePng(IntPtr h, int maxWidth) {
        RECT r; GetWindowRect(h, out r);
        int w = r.R - r.L, ht = r.B - r.T;
        if (w <= 0 || ht <= 0) throw new Exception("Window has no size (minimized?)");
        using (Bitmap full = new Bitmap(w, ht)) {
            using (Graphics g = Graphics.FromImage(full)) {
                IntPtr dc = g.GetHdc();
                PrintWindow(h, dc, 2);
                g.ReleaseHdc(dc);
            }
            Bitmap img = full;
            if (maxWidth > 0 && w > maxWidth) {
                int nh = (int)((long)ht * maxWidth / w);
                img = new Bitmap(maxWidth, nh);
                using (Graphics g2 = Graphics.FromImage(img)) {
                    g2.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g2.DrawImage(full, 0, 0, maxWidth, nh);
                }
            }
            using (MemoryStream ms = new MemoryStream()) {
                img.Save(ms, ImageFormat.Png);
                if (!object.ReferenceEquals(img, full)) img.Dispose();
                return ms.ToArray();
            }
        }
    }
}
'@
    $script:WinCapLoaded = $true
}

function Get-AspWindowHandle {
    $procId = [int](Get-ComProp (Get-AspApp) 'ProcessId')
    $t0 = Get-Date
    do {
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { return $p.MainWindowHandle }
        Start-Sleep -Milliseconds 500
    } while (((Get-Date) - $t0).TotalSeconds -lt 10)
    throw "Aspen window not found for process $procId"
}

Register-McpTool -Name 'aspen_screenshot' `
    -Description 'Capture the Aspen Plus window as a PNG image, to see the flowsheet and forms as the user sees them. Also saved under workspace\screenshots.' `
    -Properties @{ max_width = (P-Int 'Downscale to this width (default 1600)'); maximize = (P-Bool 'Maximize the Aspen window first') } `
    -Handler {
        param($a)
        Initialize-WinCap
        $h = Get-AspWindowHandle
        [AspenWinCap]::Restore($h)
        if ($a.maximize) { [AspenWinCap]::Maximize($h); Start-Sleep -Milliseconds 800 }
        $mw = if ($a.max_width) { [int]$a.max_width } else { 1600 }
        $bytes = [AspenWinCap]::CapturePng($h, $mw)
        $dir = Join-Path $global:S.Workspace 'screenshots'
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
        $file = Join-Path $dir ('aspen_' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.png')
        [IO.File]::WriteAllBytes($file, $bytes)
        @{ content = @(
                [ordered]@{ type = 'image'; data = [Convert]::ToBase64String($bytes); mimeType = 'image/png' },
                [ordered]@{ type = 'text'; text = "Saved $file" }
            ) }
    }
