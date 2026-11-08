// Unity UI Toolkit side of the comparison with godot-uxml (bench/unity_compare.gd).
// Runs in a Windows standalone player (tools/unity-bench/run.py builds it).
//
//   UnityBench.exe -benchOut <file.json> [-iters N] -screen-width 1280 -screen-height 800 -screen-fullscreen 0
//
// The documents are the files bench/unity_compare.gd --write-docs writes,
// imported by Unity into Assets/Resources/UI. The panel uses Unity's default
// runtime theme (unity-theme://default), ConstantPixelSize, scale 1.
//
// Timed region, as on the Godot side: the mutation, then the panel update
// without the repaint, called synchronously (BaseVisualElementPanel
// .UpdateWithoutRepaint, internal, by reflection; delegate built once). That
// update runs the same phases the player loop runs before it draws:
// view data, bindings, data binding, animations, styles, layout, transforms
// and clipping. The repaint (UIR mesh generation and draw) is not timed;
// godot-uxml's drawing is not timed either. The next frame is not timed.
// Times: System.Diagnostics.Stopwatch (CPU wall time).
//
// A load: a host element (absolute, the size of the Godot document), then
// VisualTreeAsset.CloneTree into it, then the update. Unity parses UXML and
// USS at import time, in the editor: the player loads a parsed asset, and
// Resources.Load caches it after the first call. godot-uxml parses the text
// in each load. That is the way each one ships.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;
using UnityEngine.UIElements;

public class UiBench : MonoBehaviour
{
    const BindingFlags Any = BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;
    const int Hover = 2;   // PseudoStates.Hover

    int iters = 60;
    string outPath = "";
    VisualElement root;
    Action update;
    PropertyInfo pseudo;
    Type pseudoType;
    readonly List<KeyValuePair<string, List<double>>> rows = new List<KeyValuePair<string, List<double>>>();
    readonly StringBuilder log = new StringBuilder();

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    static void Boot()
    {
        new GameObject("ui-bench").AddComponent<UiBench>();
    }

    IEnumerator Start()
    {
        ParkWindow();
        QualitySettings.vSyncCount = 0;
        Application.targetFrameRate = -1;
        Application.runInBackground = true;
        var args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (args[i] == "-benchOut") outPath = args[i + 1];
            if (args[i] == "-iters") iters = int.Parse(args[i + 1], CultureInfo.InvariantCulture);
        }
        var theme = Resources.Load<ThemeStyleSheet>("DefaultRuntimeTheme");
        if (theme == null) throw new Exception("no DefaultRuntimeTheme in Resources");
        var ps = ScriptableObject.CreateInstance<PanelSettings>();
        ps.themeStyleSheet = theme;
        ps.scaleMode = PanelScaleMode.ConstantPixelSize;
        ps.scale = 1f;
        var doc = gameObject.AddComponent<UIDocument>();
        doc.panelSettings = ps;
        yield return null;
        root = doc.rootVisualElement;
        var panel = root.panel;
        var m = panel.GetType().GetMethod("UpdateWithoutRepaint", Any, null, Type.EmptyTypes, null);
        if (m == null) throw new Exception("panel has no UpdateWithoutRepaint");
        update = (Action)Delegate.CreateDelegate(typeof(Action), panel, m);
        pseudo = typeof(VisualElement).GetProperty("pseudoStates", Any);
        pseudoType = pseudo.PropertyType;
        Note("unity " + Application.unityVersion + ", panel " + panel.GetType().Name +
             ", backend " + Backend() + ", debug " + UnityEngine.Debug.isDebugBuild +
             ", screen " + Screen.width + "x" + Screen.height);
        for (int k = 0; k < 10; k++) yield return null;

        yield return Big();
        yield return Hud();
        yield return Settings();
        yield return Inventory();
        yield return Dialog();
        yield return ListViewWorkload();
        yield return Frames();
        Write();
        Application.Quit(0);
    }

    // A small window (run.py passes -screen-width 640 -screen-height 400) in
    // the bottom-right corner of the work area, without activating it, so
    // that runs stay out of the way (Godot: the same, in unity_compare.gd).
    // The documents keep their own fixed sizes; the frame rows draw into
    // this window on both sides.
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, out RECT r, uint win);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
    delegate bool EnumProc(IntPtr h, IntPtr p);
    static IntPtr found;

    [AOT.MonoPInvokeCallback(typeof(EnumProc))]
    static bool OnWindow(IntPtr h, IntPtr p)
    {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        if (pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id && IsWindowVisible(h)) { found = h; return false; }
        return true;
    }

    static void ParkWindow()
    {
        try
        {
            found = IntPtr.Zero;
            EnumWindows(OnWindow, IntPtr.Zero);
            RECT area, win;
            if (found == IntPtr.Zero || !SystemParametersInfo(0x0030, 0, out area, 0) || !GetWindowRect(found, out win)) return;
            int w = win.right - win.left, h = win.bottom - win.top;
            // SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
            SetWindowPos(found, IntPtr.Zero, area.right - w - 8, area.bottom - h - 8, 0, 0, 0x0001 | 0x0004 | 0x0010);
        }
        catch (Exception e) { UnityEngine.Debug.Log("[ui-bench] window not moved: " + e.Message); }
    }

    static string Backend()
    {
#if ENABLE_IL2CPP
        return "il2cpp";
#else
        return "mono";
#endif
    }

    void Note(string s)
    {
        log.Append(s).Append('\n');
        UnityEngine.Debug.Log("[ui-bench] " + s);
    }

    // -----------------------------------------------------------------------
    // Timing

    void Record(string op, List<double> s)
    {
        rows.Add(new KeyValuePair<string, List<double>>(op, s));
        var c = new List<double>(s);
        c.Sort();
        Note(string.Format(CultureInfo.InvariantCulture, "{0,-46} n={1,-4} median {2,9:F3} ms", op, c.Count, c[c.Count / 2]));
    }

    static double Ms(long ticks) { return ticks * 1000.0 / Stopwatch.Frequency; }

    VisualElement NewHost(float w, float h)
    {
        var host = new VisualElement();
        host.style.position = Position.Absolute;
        host.style.left = 0;
        host.style.top = 0;
        host.style.width = w;
        host.style.height = h;
        root.Add(host);
        return host;
    }

    void FreeHost(VisualElement host)
    {
        host.RemoveFromHierarchy();
        update();
    }

    static VisualTreeAsset Asset(string name)
    {
        var a = Resources.Load<VisualTreeAsset>("UI/" + name);
        if (a == null) throw new Exception("no VisualTreeAsset UI/" + name);
        return a;
    }

    IEnumerator TimeLoad(string op, string asset, float w, float h, int n, Action<VisualElement> extra = null)
    {
        var vta = Asset(asset);
        var s = new List<double>();
        for (int i = 0; i < n + 2; i++)
        {
            long t0 = Stopwatch.GetTimestamp();
            var host = NewHost(w, h);
            vta.CloneTree(host);
            if (extra != null) extra(host);
            update();
            long t1 = Stopwatch.GetTimestamp();
            if (i >= 2) s.Add(Ms(t1 - t0));
            FreeHost(host);
            yield return null;
        }
        Record(op, s);
    }

    IEnumerator TimeOp(string op, Action<int> mutate, int n = -1)
    {
        if (n < 0) n = iters;
        var s = new List<double>();
        for (int i = 0; i < n + 4; i++)
        {
            long t0 = Stopwatch.GetTimestamp();
            mutate(i);
            update();
            long t1 = Stopwatch.GetTimestamp();
            if (i >= 4) s.Add(Ms(t1 - t0));
            yield return null;
        }
        Record(op, s);
    }

    VisualElement Load(string asset, float w, float h)
    {
        var host = NewHost(w, h);
        Asset(asset).CloneTree(host);
        update();
        return host;
    }

    void SetHover(VisualElement e, bool on)
    {
        int v = Convert.ToInt32(pseudo.GetValue(e), CultureInfo.InvariantCulture);
        v = on ? (v | Hover) : (v & ~Hover);
        pseudo.SetValue(e, Enum.ToObject(pseudoType, v));
    }

    static VisualElement Q(VisualElement host, string name)
    {
        var e = host.Q(name);
        if (e == null) throw new Exception("no element " + name);
        return e;
    }

    static int Count(VisualElement e)
    {
        int n = 1;
        foreach (var c in e.hierarchy.Children()) n += Count(c);
        return n;
    }

    void Check(string what, VisualElement e)
    {
        var r = e.worldBound;
        Note(string.Format(CultureInfo.InvariantCulture, "check {0}: {1:F1},{2:F1} {3:F1}x{4:F1}", what, r.x, r.y, r.width, r.height));
    }

    // -----------------------------------------------------------------------
    // Workloads

    IEnumerator Big()
    {
        yield return TimeLoad("big: load", "big", 1280, 800, Math.Max(10, iters / 4));
        // Load until the end of the first frame drawn after it (the repaint included).
        var vta = Asset("big");
        var fs = new List<double>();
        for (int i = 0; i < Math.Max(10, iters / 4) + 2; i++)
        {
            long t0 = Stopwatch.GetTimestamp();
            var f = NewHost(1280, 800);
            vta.CloneTree(f);
            yield return new WaitForEndOfFrame();
            long t1 = Stopwatch.GetTimestamp();
            if (i >= 2) fs.Add(Ms(t1 - t0));
            FreeHost(f);
            yield return null;
        }
        Record("big: load + first frame", fs);
        var d = Load("big", 1280, 800);
        for (int k = 0; k < 3; k++) yield return null;
        Note("big: " + Count(d) + " visual elements (control parts included)");
        Check("card-0", Q(d, "card-0"));
        Check("card-149", Q(d, "card-149"));
        var ok = Q(d, "card-7-ok");
        yield return TimeOp("big: hover toggle (button)", i => SetHover(ok, i % 2 == 0));
        var card12 = Q(d, "card-12");
        yield return TimeOp("big: hover toggle (card, descendant selector)", i => SetHover(card12, i % 2 == 0));
        yield return TimeOp("big: restyle, no change", i => { });
        var card20 = Q(d, "card-20");
        yield return TimeOp("big: class change (card)", i => card20.EnableInClassList("card--selected", i % 2 == 0));
        var body = (Label)Q(d, "card-30-body");
        yield return TimeOp("big: label text change + layout", i =>
            body.text = i % 2 == 0 ? "short" : "a much longer body text that wraps over lines");
        yield return TimeOp("big: resize", i =>
        {
            d.style.width = i % 2 == 0 ? 1024 : 1280;
            d.style.height = i % 2 == 0 ? 720 : 800;
        });
        FreeHost(d);
    }

    IEnumerator Hud()
    {
        var d = Load("hud", 640, 360);
        for (int k = 0; k < 3; k++) yield return null;
        var labels = new Label[8];
        for (int k = 0; k < 8; k++) labels[k] = (Label)Q(d, "val-" + k);
        yield return TimeOp("hud: frame, 8 labels + layout", i =>
        {
            for (int k = 0; k < labels.Length; k++)
                labels[k].text = ((i * 37 + k * 101) % 100000).ToString(CultureInfo.InvariantCulture);
        }, iters * 3);
        var bar = Q(d, "bar-0");
        yield return TimeOp("hud: hover toggle", i => SetHover(bar, i % 2 == 0), iters * 3);
        FreeHost(d);
    }

    IEnumerator Settings()
    {
        yield return TimeLoad("settings: load", "wl_settings", 1280, 720, iters / 2);
        var d = Load("wl_settings", 1280, 720);
        for (int k = 0; k < 3; k++) yield return null;
        var pages = new VisualElement[4];
        var tabs = new VisualElement[4];
        for (int t = 0; t < 4; t++) { pages[t] = Q(d, "page-" + t); tabs[t] = Q(d, "tab-" + t); }
        yield return TimeOp("settings: switch tab", i =>
        {
            for (int t = 0; t < 4; t++)
            {
                pages[t].EnableInClassList("hidden", t != i % 4);
                tabs[t].EnableInClassList("tab--on", t == i % 4);
            }
        });
        var rowsEl = new VisualElement[12];
        for (int r = 0; r < 12; r++) rowsEl[r] = Q(d, "row-0-" + r);
        yield return TimeOp("settings: hover row", i => SetHover(rowsEl[i % 12], i % 2 == 0));
        FreeHost(d);
    }

    IEnumerator Inventory()
    {
        yield return TimeLoad("inventory: load", "wl_inventory", 1280, 720, iters / 2);
        var d = Load("wl_inventory", 1280, 720);
        for (int k = 0; k < 3; k++) yield return null;
        var slots = new VisualElement[80];
        var counts = new Label[80];
        for (int k = 0; k < 80; k++) { slots[k] = Q(d, "slot-" + k); counts[k] = (Label)Q(d, "count-" + k); }
        Check("slot-79", slots[79]);
        yield return TimeOp("inventory: hover slot", i =>
        {
            SetHover(slots[i % 80], true);
            SetHover(slots[(i + 79) % 80], false);
        });
        yield return TimeOp("inventory: select slot", i =>
        {
            slots[i % 80].EnableInClassList("slot--selected", true);
            slots[(i + 79) % 80].EnableInClassList("slot--selected", false);
        });
        yield return TimeOp("inventory: count change + layout", i =>
            counts[i % 80].text = (i * 7 % 999).ToString(CultureInfo.InvariantCulture));
        FreeHost(d);
    }

    const string DialogText = "The lighthouse keeper looked at you for a long time before speaking. \"Nobody comes out here in winter,\" she said, \"not unless they are running from something, or towards it.\"";

    IEnumerator Dialog()
    {
        yield return TimeLoad("dialog: load", "wl_dialog", 1280, 720, iters / 2);
        var d = Load("wl_dialog", 1280, 720);
        for (int k = 0; k < 3; k++) yield return null;
        var body = (Label)Q(d, "body");
        yield return TimeOp("dialog: typewriter character + layout", i =>
            body.text = DialogText.Substring(0, 1 + (i * 3) % DialogText.Length), iters * 2);
        Check("dialog body", body);
        var choices = new VisualElement[4];
        for (int c = 0; c < 4; c++) choices[c] = Q(d, "choice-" + c);
        yield return TimeOp("dialog: hover choice", i => SetHover(choices[i % 4], i % 2 == 0));
        FreeHost(d);
    }

    static readonly List<int> Items = MakeItems();

    static List<int> MakeItems()
    {
        var l = new List<int>(10000);
        for (int i = 0; i < 10000; i++) l.Add(i);
        return l;
    }

    static void SetupList(VisualElement host)
    {
        var lv = host.Q<ListView>("list");
        if (lv == null) throw new Exception("no ListView");
        if (lv.itemTemplate == null) lv.itemTemplate = Asset("wl_row");
        lv.bindItem = (e, i) =>
        {
            e.Q<Label>("lname").text = "Entry " + i.ToString(CultureInfo.InvariantCulture);
            e.Q<Label>("lval").text = (i * 3).ToString(CultureInfo.InvariantCulture);
        };
        lv.itemsSource = Items;
    }

    IEnumerator ListViewWorkload()
    {
        yield return TimeLoad("listview: load, 10,000 items", "wl_listview", 1280, 720, iters / 2, SetupList);
        var d = NewHost(1280, 720);
        Asset("wl_listview").CloneTree(d);
        SetupList(d);
        update();
        for (int k = 0; k < 3; k++) yield return null;
        var lv = d.Q<ListView>("list");
        var sv = lv.Q<ScrollView>();
        Note("listview: template " + (lv.itemTemplate != null ? lv.itemTemplate.name : "none") +
             ", " + sv.contentContainer.childCount + " rows made");
        yield return TimeOp("listview: scroll 3 rows", i =>
            sv.scrollOffset = new Vector2(0, ((i + 1) * 72) % 200000), iters * 2);
        // Check: the first row in the viewport shows the item at the offset.
        var off = sv.scrollOffset.y;
        string first = "";
        float best = float.MaxValue;
        foreach (var row in sv.contentContainer.Children())
        {
            float y = row.layout.y;
            if (y >= off - 1 && y < best) { best = y; first = row.Q<Label>("lname").text; }
        }
        Note(string.Format(CultureInfo.InvariantCulture, "listview check: offset {0}, first row '{1}' (want Entry {2})", off, first, (int)(off / 24)));
        yield return TimeOp("listview: rebind visible items", i => lv.RefreshItems());
        FreeHost(d);
    }

    IEnumerator Frames()
    {
        yield return FrameSeries("frame: empty scene");
        var d = Load("big", 1280, 800);
        for (int k = 0; k < 30; k++) yield return null;
        yield return FrameSeries("frame: big document, idle");
        FreeHost(d);
    }

    IEnumerator FrameSeries(string op)
    {
        for (int k = 0; k < 30; k++) yield return null;
        var s = new List<double>();
        long t0 = Stopwatch.GetTimestamp();
        for (int k = 0; k < 300; k++)
        {
            yield return null;
            long t1 = Stopwatch.GetTimestamp();
            s.Add(Ms(t1 - t0));
            t0 = t1;
        }
        Record(op, s);
    }

    // -----------------------------------------------------------------------

    static string Esc(string s) { return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n"); }

    void Write()
    {
        var sb = new StringBuilder();
        sb.Append("{\"meta\": {\"side\": \"unity\", \"engine\": \"").Append(Application.unityVersion)
          .Append("\", \"backend\": \"").Append(Backend())
          .Append("\", \"debug_build\": ").Append(UnityEngine.Debug.isDebugBuild ? "true" : "false")
          .Append(", \"cpu\": \"").Append(Esc(SystemInfo.processorType))
          .Append("\", \"os\": \"").Append(Esc(SystemInfo.operatingSystem))
          .Append("\", \"log\": \"").Append(Esc(log.ToString())).Append("\"},\n\"rows\": [\n");
        for (int r = 0; r < rows.Count; r++)
        {
            sb.Append(" {\"op\": \"").Append(Esc(rows[r].Key)).Append("\", \"samples\": [");
            var s = rows[r].Value;
            for (int i = 0; i < s.Count; i++)
            {
                if (i > 0) sb.Append(", ");
                sb.Append(s[i].ToString("R", CultureInfo.InvariantCulture));
            }
            sb.Append("]}").Append(r < rows.Count - 1 ? ",\n" : "\n");
        }
        sb.Append("]}\n");
        if (outPath.Length > 0) File.WriteAllText(outPath, sb.ToString());
        UnityEngine.Debug.Log("UCMP_COMPLETE");
    }
}
