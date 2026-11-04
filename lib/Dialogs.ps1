# Modal-dialog watchdog. Aspen sometimes raises a dialog that SuppressDialogs does not cover
# (e.g. "Copy Units From" when the global unit set changes). A COM call then blocks forever.
# A thread-pool timer watches the Aspen process for standard dialog boxes (#32770): titles on the
# confirm list get OK pressed, anything else is closed (same as pressing X / Cancel). Every action
# is recorded so the tool result can tell the caller what happened.

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;

public static class AspenDialogWatch {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    static Timer timer;
    static volatile int watchPid;
    static string[] confirmTitles = new string[0];
    static readonly ConcurrentDictionary<IntPtr, DateTime> firstSeen = new ConcurrentDictionary<IntPtr, DateTime>();
    public static readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();
    public static int GraceMs = 1500;

    public static void Start(int pid, string[] confirm) {
        watchPid = pid;
        confirmTitles = confirm ?? new string[0];
        if (timer == null) timer = new Timer(Tick, null, 500, 500);
    }
    public static void Stop() { watchPid = 0; }

    static string Text(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
    static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }

    static void Tick(object state) {
        int pid = watchPid;
        if (pid == 0) return;
        try {
            var seen = new HashSet<IntPtr>();
            EnumWindows((h, l) => {
                uint p; GetWindowThreadProcessId(h, out p);
                if (p == (uint)pid && IsWindowVisible(h) && Cls(h) == "#32770") {
                    seen.Add(h);
                    DateTime t0 = firstSeen.GetOrAdd(h, DateTime.Now);
                    if ((DateTime.Now - t0).TotalMilliseconds >= GraceMs) Handle(h);
                }
                return true;
            }, IntPtr.Zero);
            foreach (var k in firstSeen.Keys) if (!seen.Contains(k)) { DateTime d; firstSeen.TryRemove(k, out d); }
        } catch { }
    }

    static void Handle(IntPtr dlg) {
        string title = Text(dlg);
        var texts = new List<string>();
        IntPtr ok = IntPtr.Zero;
        EnumChildWindows(dlg, (c, l) => {
            string cls = Cls(c), t = Text(c).Replace("&", "");
            if (cls == "Button" && (t == "OK" || t == "Yes")) { if (ok == IntPtr.Zero) ok = c; }
            else if (cls == "Static" && t.Trim().Length > 0) texts.Add(t.Trim());
            return true;
        }, IntPtr.Zero);
        bool confirm = false;
        foreach (var c in confirmTitles) if (string.Equals(c, title, StringComparison.OrdinalIgnoreCase)) confirm = true;
        string body = string.Join(" / ", texts.ToArray());
        if (confirm && ok != IntPtr.Zero) {
            PostMessage(ok, 0x00F5, IntPtr.Zero, IntPtr.Zero);              // BM_CLICK
            Events.Enqueue("Aspen dialog '" + title + "' was confirmed (OK). " + body);
        } else {
            PostMessage(dlg, 0x0010, IntPtr.Zero, IntPtr.Zero);             // WM_CLOSE
            Events.Enqueue("Aspen dialog '" + title + "' was closed without confirming. " + body);
        }
        DateTime d; firstSeen.TryRemove(dlg, out d);
    }

    public static string[] Drain() {
        var list = new List<string>(); string s;
        while (Events.TryDequeue(out s)) list.Add(s);
        return list.ToArray();
    }
}
'@

function Start-DialogWatch($app) {
    try {
        $procId = [int](Get-ComProp $app 'ProcessId')
        [AspenDialogWatch]::Start($procId, [string[]]@($global:S.Config.confirm_dialogs))
    } catch { Write-McpLog "dialog watch not started: $(Get-ErrorText $_)" }
}
