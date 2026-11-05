// Unity ground truth for godot-uxml.
//
// Loads each case (UXML + USS) into a runtime panel that uses Unity's default
// runtime theme, at a fixed size and pixelsPerPoint 1, forces styles and
// layout, and writes one JSON file per case with every element, control parts
// included: type, name, classes, parent chain, content container, panel-space
// rect, pseudo-states, text measure and the resolved style.
//
// Run through tools/unity-dump/run.py, or directly:
//   Unity.exe -batchmode -nographics -projectPath tools/unity-dump
//     -executeMethod UxmlDump.Run -dumpCases Assets/Cases -dumpOut <dir> -quit
//
// A case is a folder Assets/Cases/<name>/ with <name>.uxml, an optional
// <name>.uss (attached to the case root) and an optional <name>.json sidecar:
//   { "width": 400, "height": 300,
//     "actions": [ {"op": "focus", "target": "name"},
//                  {"op": "pointer-move", "x": 10, "y": 10},
//                  {"op": "pointer-down", "x": 10, "y": 10},
//                  {"op": "pointer-up", "x": 10, "y": 10},
//                  {"op": "click", "target": "name"},
//                  {"op": "key", "target": "name", "key": "Space"},
//                  {"op": "force-state", "target": "name", "states": ["hover"]},
//                  {"op": "items", "target": "list", "count": 20},
//                  {"op": "items", "target": "list", "values": ["a", "b"]},
//                  {"op": "tree-items", "target": "tree", "items": [{"id": 1, "data": "a", "children": [...]}], "expand": true},
//                  {"op": "scroll", "target": "sv", "x": 0, "y": 40},
//                  {"op": "select", "target": "list", "indices": [1]},
//                  {"op": "wheel", "x": 10, "y": 10, "dy": 1} ] }
// "target" names an element by `name`; "path" (e.g. "0/1/0") reaches parts.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

public static class UxmlDump
{
    const string ThemePath = "Assets/Theme/DefaultRuntimeTheme.tss";
    const BindingFlags Any = BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;

    static string Arg(string name, string fallback)
    {
        var args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == name) return args[i + 1];
        return fallback;
    }

    public static void Run()
    {
        int exit = 0;
        try
        {
            string casesDir = Arg("-dumpCases", "Assets/Cases");
            string outDir = Arg("-dumpOut", Path.GetFullPath("dump-out"));
            string only = Arg("-dumpOnly", "");
            Directory.CreateDirectory(outDir);
            AssetDatabase.Refresh(ImportAssetOptions.ForceSynchronousImport);
            var dirs = Directory.GetDirectories(casesDir).OrderBy(d => d, StringComparer.Ordinal).ToList();
            foreach (var dir in dirs)
            {
                string name = Path.GetFileName(dir);
                if (only.Length > 0 && !only.Split(',').Contains(name)) continue;
                try
                {
                    string json = DumpCase(dir.Replace('\\', '/'), name);
                    File.WriteAllText(Path.Combine(outDir, name + ".json"), json, new UTF8Encoding(false));
                    Debug.Log("[uxml-dump] wrote " + name);
                }
                catch (Exception e)
                {
                    exit = 1;
                    Debug.LogError("[uxml-dump] case " + name + " failed: " + e);
                }
            }
        }
        catch (Exception e)
        {
            exit = 2;
            Debug.LogError("[uxml-dump] " + e);
        }
        EditorApplication.Exit(exit);
    }

    // -----------------------------------------------------------------------

    class Sidecar
    {
        public int width = 400;
        public int height = 300;
        public List<Dictionary<string, object>> actions = new List<Dictionary<string, object>>();
    }

    static Sidecar ReadSidecar(string path)
    {
        var sc = new Sidecar();
        if (!File.Exists(path)) return sc;
        var obj = MiniJson.Parse(File.ReadAllText(path)) as Dictionary<string, object>;
        if (obj == null) return sc;
        if (obj.TryGetValue("width", out var w)) sc.width = Convert.ToInt32(w, CultureInfo.InvariantCulture);
        if (obj.TryGetValue("height", out var h)) sc.height = Convert.ToInt32(h, CultureInfo.InvariantCulture);
        if (obj.TryGetValue("actions", out var a) && a is List<object> list)
            foreach (var x in list)
                if (x is Dictionary<string, object> d) sc.actions.Add(d);
        return sc;
    }

    static string DumpCase(string dir, string name)
    {
        var sc = ReadSidecar(Path.Combine(dir, name + ".json"));
        var vta = AssetDatabase.LoadAssetAtPath<VisualTreeAsset>(dir + "/" + name + ".uxml");
        if (vta == null) throw new Exception("no VisualTreeAsset at " + dir + "/" + name + ".uxml");
        var uss = AssetDatabase.LoadAssetAtPath<StyleSheet>(dir + "/" + name + ".uss");
        var theme = AssetDatabase.LoadAssetAtPath<ThemeStyleSheet>(ThemePath);
        if (theme == null) throw new Exception("no default runtime theme at " + ThemePath);

        var rt = new RenderTexture(sc.width, sc.height, 0);
        var ps = ScriptableObject.CreateInstance<PanelSettings>();
        ps.themeStyleSheet = theme;
        ps.scaleMode = PanelScaleMode.ConstantPixelSize;
        ps.scale = 1f;
        ps.referenceDpi = 96f;
        ps.fallbackDpi = 96f;
        ps.targetTexture = rt;
        ps.clearColor = false;

        var go = new GameObject("uxml-dump");
        try
        {
            var docu = go.AddComponent<UIDocument>();
            docu.panelSettings = ps;
            var docRoot = docu.rootVisualElement;
            if (docRoot == null) throw new Exception("UIDocument has no rootVisualElement in edit mode");
            var panel = docRoot.panel;

            // The case root: a fixed-size host at the panel origin, so geometry
            // does not depend on how the panel sizes its root in batch mode.
            var host = new VisualElement();
            host.name = "uxml-dump-host";
            host.style.position = Position.Absolute;
            host.style.left = 0;
            host.style.top = 0;
            host.style.width = sc.width;
            host.style.height = sc.height;
            docRoot.Add(host);
            vta.CloneTree(host);
            if (uss != null) host.styleSheets.Add(uss);
            Validate(panel);

            var log = new List<string>();
            foreach (var act in sc.actions)
            {
                log.Add(RunAction(act, host, panel));
                Validate(panel);
            }
            Validate(panel);

            var w = new JsonWriter();
            w.BeginObject();
            w.Key("case"); w.Value(name);
            w.Key("metadata"); WriteMetadata(w, panel);
            w.Key("panel"); w.BeginObject(); w.Key("width"); w.Value(sc.width); w.Key("height"); w.Value(sc.height); w.EndObject();
            w.Key("actions"); w.BeginArray(); foreach (var l in log) w.Value(l); w.EndArray();
            w.Key("focused");
            var focused = panel.focusController != null ? panel.focusController.focusedElement as VisualElement : null;
            if (focused != null && IsUnder(focused, host)) w.Value(PathOf(focused, host)); else w.Null();
            w.Key("elements"); w.BeginArray();
            int index = 0;
            foreach (var child in host.hierarchy.Children())
                WriteElement(w, child, host, index++.ToString(CultureInfo.InvariantCulture));
            w.EndArray();
            w.EndObject();
            return w.ToString();
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(go);
            UnityEngine.Object.DestroyImmediate(ps);
            rt.Release();
            UnityEngine.Object.DestroyImmediate(rt);
        }
    }

    // Styles, layout and transforms, the way the panel does before a repaint.
    static void Validate(IPanel panel)
    {
        for (int pass = 0; pass < 8; pass++)
        {
            var m = panel.GetType().GetMethod("ValidateLayout", Any, null, Type.EmptyTypes, null);
            if (m == null) throw new Exception("panel has no ValidateLayout");
            m.Invoke(panel, null);
            var u = panel.GetType().GetMethod("UpdateForRepaint", Any, null, Type.EmptyTypes, null);
            if (u != null) { try { u.Invoke(panel, null); } catch { } }
        }
    }

    static void WriteMetadata(JsonWriter w, IPanel panel)
    {
        w.BeginObject();
        w.Key("unityVersion"); w.Value(Application.unityVersion);
        w.Key("theme"); w.Value("unity-theme://default (runtime)");
        w.Key("pixelsPerPoint");
        var ppp = panel.GetType().GetProperty("scaledPixelsPerPoint", Any);
        if (ppp != null) w.Value(Convert.ToDouble(ppp.GetValue(panel), CultureInfo.InvariantCulture)); else w.Null();
        w.Key("contextType"); w.Value(panel.contextType.ToString());
        w.Key("dumpedAtUtc"); w.Value(DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
        w.EndObject();
    }

    // -----------------------------------------------------------------------
    // Actions

    static VisualElement Find(Dictionary<string, object> act, VisualElement host)
    {
        if (act.TryGetValue("path", out var p))
            return ByPath(host, Convert.ToString(p, CultureInfo.InvariantCulture));
        if (act.TryGetValue("target", out var t))
        {
            string n = Convert.ToString(t, CultureInfo.InvariantCulture);
            return host.Query<VisualElement>(n).First();
        }
        return null;
    }

    static VisualElement ByPath(VisualElement host, string path)
    {
        VisualElement cur = host;
        foreach (var seg in path.Split('/'))
        {
            int i = int.Parse(seg, CultureInfo.InvariantCulture);
            if (i >= cur.hierarchy.childCount) return null;
            cur = cur.hierarchy[i];
        }
        return cur;
    }

    static Vector2 PointOf(Dictionary<string, object> act, VisualElement target)
    {
        if (act.TryGetValue("x", out var x) && act.TryGetValue("y", out var y))
            return new Vector2(Convert.ToSingle(x, CultureInfo.InvariantCulture), Convert.ToSingle(y, CultureInfo.InvariantCulture));
        if (target != null) return target.worldBound.center;
        return Vector2.zero;
    }

    static void SendImgui(IPanel panel, EventType type, Vector2 pos, KeyCode key = KeyCode.None, char ch = '\0')
    {
        var e = new Event { type = type, mousePosition = pos, button = 0, keyCode = key, character = ch, clickCount = 1 };
        EventBase evt;
        switch (type)
        {
            case EventType.MouseMove: evt = PointerMoveEvent.GetPooled(e); break;
            case EventType.MouseDown: evt = PointerDownEvent.GetPooled(e); break;
            case EventType.MouseUp: evt = PointerUpEvent.GetPooled(e); break;
            case EventType.KeyDown: evt = KeyDownEvent.GetPooled(e); break;
            case EventType.KeyUp: evt = KeyUpEvent.GetPooled(e); break;
            default: return;
        }
        using (evt) panel.visualTree.SendEvent(evt);
    }

    static string RunAction(Dictionary<string, object> act, VisualElement host, IPanel panel)
    {
        string op = Convert.ToString(act.TryGetValue("op", out var o) ? o : "", CultureInfo.InvariantCulture);
        var target = Find(act, host);
        switch (op)
        {
            case "focus":
                if (target == null) return "focus: no target";
                target.Focus();
                return "focus " + PathOf(target, host);
            case "pointer-move":
                SendImgui(panel, EventType.MouseMove, PointOf(act, target));
                return "pointer-move " + PointOf(act, target);
            case "pointer-down":
                SendImgui(panel, EventType.MouseMove, PointOf(act, target));
                SendImgui(panel, EventType.MouseDown, PointOf(act, target));
                return "pointer-down " + PointOf(act, target);
            case "pointer-up":
                SendImgui(panel, EventType.MouseUp, PointOf(act, target));
                return "pointer-up " + PointOf(act, target);
            case "click":
                SendImgui(panel, EventType.MouseMove, PointOf(act, target));
                SendImgui(panel, EventType.MouseDown, PointOf(act, target));
                SendImgui(panel, EventType.MouseUp, PointOf(act, target));
                return "click " + PointOf(act, target);
            case "key":
            {
                if (target != null) target.Focus();
                var kc = (KeyCode)Enum.Parse(typeof(KeyCode), Convert.ToString(act["key"], CultureInfo.InvariantCulture));
                char ch = kc == KeyCode.Space ? ' ' : (kc == KeyCode.Return ? '\n' : '\0');
                SendImgui(panel, EventType.KeyDown, Vector2.zero, kc, '\0');
                if (ch != '\0') SendImgui(panel, EventType.KeyDown, Vector2.zero, KeyCode.None, ch);
                SendImgui(panel, EventType.KeyUp, Vector2.zero, kc, '\0');
                return "key " + kc;
            }
            case "force-state":
            {
                if (target == null) return "force-state: no target";
                var prop = typeof(VisualElement).GetProperty("pseudoStates", Any);
                int bits = Convert.ToInt32(prop.GetValue(target));
                var names = Enum.GetNames(prop.PropertyType);
                foreach (var s in (List<object>)act["states"])
                {
                    string want = Convert.ToString(s, CultureInfo.InvariantCulture);
                    foreach (var n in names)
                        if (string.Equals(n, want, StringComparison.OrdinalIgnoreCase))
                            bits |= Convert.ToInt32(Enum.Parse(prop.PropertyType, n));
                }
                prop.SetValue(target, Enum.ToObject(prop.PropertyType, bits));
                return "force-state " + PathOf(target, host);
            }
            case "set-value":
            {
                if (target == null) return "set-value: no target";
                var vp = target.GetType().GetProperty("value", BindingFlags.Instance | BindingFlags.Public);
                if (vp == null) return "set-value: no value property";
                object v = act["value"];
                if (vp.PropertyType == typeof(bool)) v = Convert.ToBoolean(v, CultureInfo.InvariantCulture);
                else if (vp.PropertyType == typeof(float)) v = Convert.ToSingle(v, CultureInfo.InvariantCulture);
                else if (vp.PropertyType == typeof(int)) v = Convert.ToInt32(v, CultureInfo.InvariantCulture);
                else if (vp.PropertyType == typeof(string)) v = Convert.ToString(v, CultureInfo.InvariantCulture);
                vp.SetValue(target, v);
                return "set-value " + PathOf(target, host);
            }
            case "items":
            {
                if (!(target is BaseVerticalCollectionView cv)) return "items: no collection view";
                var list = new List<string>();
                if (act.TryGetValue("values", out var vals) && vals is List<object> vl)
                    foreach (var x in vl) list.Add(Convert.ToString(x, CultureInfo.InvariantCulture));
                else
                {
                    int n = act.TryGetValue("count", out var c) ? Convert.ToInt32(c, CultureInfo.InvariantCulture) : 0;
                    for (int i = 0; i < n; i++) list.Add("Item " + i.ToString(CultureInfo.InvariantCulture));
                }
                cv.itemsSource = list;
                cv.Rebuild();
                return "items " + PathOf(target, host) + " " + list.Count;
            }
            case "tree-items":
            {
                if (!(target is BaseTreeView tv)) return "tree-items: no tree view";
                var roots = TreeItems(act.TryGetValue("items", out var ti) ? ti as List<object> : null);
                var m = tv.GetType().GetMethods(BindingFlags.Instance | BindingFlags.Public)
                    .First(x => x.Name == "SetRootItems" && x.IsGenericMethod);
                m.MakeGenericMethod(typeof(string)).Invoke(tv, new object[] { roots });
                if (act.TryGetValue("expand", out var ex) && Convert.ToBoolean(ex, CultureInfo.InvariantCulture)) tv.ExpandAll();
                tv.Rebuild();
                return "tree-items " + PathOf(target, host) + " " + roots.Count;
            }
            case "scroll":
            {
                ScrollView sv = target as ScrollView;
                if (sv == null && target != null) sv = target.Q<ScrollView>();
                if (sv == null) return "scroll: no scroll view";
                float x = act.TryGetValue("x", out var sx) ? Convert.ToSingle(sx, CultureInfo.InvariantCulture) : 0f;
                float y = act.TryGetValue("y", out var sy) ? Convert.ToSingle(sy, CultureInfo.InvariantCulture) : 0f;
                sv.scrollOffset = new Vector2(x, y);
                return "scroll " + PathOf(sv, host) + " " + sv.scrollOffset;
            }
            case "select":
            {
                if (!(target is BaseVerticalCollectionView cv)) return "select: no collection view";
                var idx = new List<int>();
                if (act.TryGetValue("indices", out var ii) && ii is List<object> il)
                    foreach (var x in il) idx.Add(Convert.ToInt32(x, CultureInfo.InvariantCulture));
                cv.SetSelection(idx);
                return "select " + PathOf(target, host) + " " + string.Join(",", idx);
            }
            case "wheel":
            {
                var pos = PointOf(act, target);
                float dy = act.TryGetValue("dy", out var wy) ? Convert.ToSingle(wy, CultureInfo.InvariantCulture) : 0f;
                float dx = act.TryGetValue("dx", out var wx) ? Convert.ToSingle(wx, CultureInfo.InvariantCulture) : 0f;
                SendImgui(panel, EventType.MouseMove, pos);
                var e = new Event { type = EventType.ScrollWheel, mousePosition = pos, delta = new Vector2(dx, dy) };
                using (var evt = WheelEvent.GetPooled(e)) panel.visualTree.SendEvent(evt);
                return "wheel " + pos + " " + dx + "," + dy;
            }
            default:
                return "unknown op " + op;
        }
    }

    static List<TreeViewItemData<string>> TreeItems(List<object> src)
    {
        var outList = new List<TreeViewItemData<string>>();
        if (src == null) return outList;
        foreach (var o in src)
        {
            if (!(o is Dictionary<string, object> d)) continue;
            int id = Convert.ToInt32(d["id"], CultureInfo.InvariantCulture);
            string data = d.TryGetValue("data", out var dd) ? Convert.ToString(dd, CultureInfo.InvariantCulture) : id.ToString(CultureInfo.InvariantCulture);
            var kids = TreeItems(d.TryGetValue("children", out var k) ? k as List<object> : null);
            outList.Add(new TreeViewItemData<string>(id, data, kids));
        }
        return outList;
    }

    // -----------------------------------------------------------------------
    // Elements

    static bool IsUnder(VisualElement e, VisualElement host)
    {
        for (var p = e; p != null; p = p.hierarchy.parent)
            if (p == host) return true;
        return false;
    }

    static string PathOf(VisualElement e, VisualElement host)
    {
        var segs = new List<string>();
        for (var p = e; p != null && p != host; p = p.hierarchy.parent)
        {
            var parent = p.hierarchy.parent;
            if (parent == null) break;
            segs.Add(parent.hierarchy.IndexOf(p).ToString(CultureInfo.InvariantCulture));
        }
        segs.Reverse();
        return string.Join("/", segs);
    }

    static string Label(VisualElement e)
    {
        return e.GetType().Name + (string.IsNullOrEmpty(e.name) ? "" : "#" + e.name);
    }

    static void WriteElement(JsonWriter w, VisualElement e, VisualElement host, string path)
    {
        w.BeginObject();
        w.Key("path"); w.Value(path);
        w.Key("type"); w.Value(e.GetType().Name);
        w.Key("fullType"); w.Value(e.GetType().FullName);
        w.Key("name"); w.Value(e.name ?? "");
        w.Key("classes"); w.BeginArray(); foreach (var c in e.GetClasses()) w.Value(c); w.EndArray();
        var parent = e.hierarchy.parent;
        w.Key("parent"); if (parent == host) w.Value(""); else w.Value(PathOf(parent, host));
        w.Key("parentChain"); w.BeginArray();
        for (var p = parent; p != null && p != host; p = p.hierarchy.parent) w.Value(Label(p));
        w.EndArray();
        // Where author children of this element go.
        w.Key("contentContainer");
        var cc = e.contentContainer;
        if (cc == null) w.Null();
        else if (cc == e) w.Value(path);
        else if (IsUnder(cc, e)) w.Value(PathOf(cc, host));
        else w.Value("(outside)");
        w.Key("isContentContainer"); w.Value(parent != null && parent != host && parent.contentContainer == e);
        w.Key("logicalChildren"); w.Value(e.childCount);
        w.Key("hierarchyChildren"); w.Value(e.hierarchy.childCount);

        var wb = e.worldBound;
        var hb = host.worldBound;
        w.Key("rect"); w.BeginObject();
        w.Key("x"); w.Value(wb.x - hb.x); w.Key("y"); w.Value(wb.y - hb.y);
        w.Key("width"); w.Value(wb.width); w.Key("height"); w.Value(wb.height);
        w.EndObject();
        var lb = e.layout;
        w.Key("layout"); w.BeginObject();
        w.Key("x"); w.Value(lb.x); w.Key("y"); w.Value(lb.y);
        w.Key("width"); w.Value(lb.width); w.Key("height"); w.Value(lb.height);
        w.EndObject();
        var cr = e.contentRect;
        w.Key("contentRect"); w.BeginObject();
        w.Key("x"); w.Value(cr.x); w.Key("y"); w.Value(cr.y);
        w.Key("width"); w.Value(cr.width); w.Key("height"); w.Value(cr.height);
        w.EndObject();

        w.Key("pseudoStates"); w.BeginArray();
        var psp = typeof(VisualElement).GetProperty("pseudoStates", Any);
        if (psp != null)
        {
            int bits = Convert.ToInt32(psp.GetValue(e));
            foreach (var n in Enum.GetNames(psp.PropertyType))
            {
                int b = Convert.ToInt32(Enum.Parse(psp.PropertyType, n));
                if (b != 0 && (bits & b) == b) w.Value(n.ToLowerInvariant());
            }
        }
        w.EndArray();
        w.Key("focusable"); w.Value(e.focusable);
        w.Key("canGrabFocus"); w.Value(e.canGrabFocus);
        w.Key("tabIndex"); w.Value(e.tabIndex);
        w.Key("delegatesFocus"); w.Value(e.delegatesFocus);
        w.Key("pickingMode"); w.Value(e.pickingMode.ToString());
        w.Key("enabledSelf"); w.Value(e.enabledSelf);
        w.Key("enabledInHierarchy"); w.Value(e.enabledInHierarchy);
        w.Key("visible"); w.Value(e.visible);

        if (e is TextElement te)
        {
            w.Key("text"); w.Value(te.text ?? "");
            var m = te.MeasureTextSize(te.text ?? "", 0, VisualElement.MeasureMode.Undefined, 0, VisualElement.MeasureMode.Undefined);
            w.Key("textMeasure"); w.BeginObject(); w.Key("width"); w.Value(m.x); w.Key("height"); w.Value(m.y); w.EndObject();
        }
        WriteValueProperty(w, e);

        w.Key("style"); WriteResolved(w, e);
        w.Key("children"); w.BeginArray();
        for (int i = 0; i < e.hierarchy.childCount; i++)
            w.Value(path + "/" + i.ToString(CultureInfo.InvariantCulture));
        w.EndArray();
        w.EndObject();
        for (int i = 0; i < e.hierarchy.childCount; i++)
            WriteElement(w, e.hierarchy[i], host, path + "/" + i.ToString(CultureInfo.InvariantCulture));
    }

    // Public value-ish properties of controls (value, lowValue, title, ...).
    static readonly string[] ValueProps = {
        "value", "lowValue", "highValue", "title", "label", "text", "delay", "interval",
        "messageType", "isMultipleSelection", "allowEmptySelection", "choices", "index",
        "scrollOffset", "mode", "horizontalScrollerVisibility", "verticalScrollerVisibility",
        "elasticity", "touchScrollBehavior", "scrollDecelerationRate", "mouseWheelScrollSize",
        "horizontalPageSize", "verticalPageSize", "nestedInteractionKind", "direction",
        "selectedIndex", "selectedIndices", "selectionType", "fixedItemHeight", "virtualizationMethod",
        "showBorder", "showAlternatingRowBackgrounds", "reorderable", "reorderMode",
        "showFoldoutHeader", "headerTitle", "showAddRemoveFooter", "showBoundCollectionSize",
        "horizontalScrollingEnabled", "sortingMode", "orientation", "fixedPaneIndex",
        "fixedPaneInitialDimension", "selectedTabIndex", "closeable", "viewDataKey",
    };

    static void WriteValueProperty(JsonWriter w, VisualElement e)
    {
        w.Key("props"); w.BeginObject();
        foreach (var pn in ValueProps)
        {
            PropertyInfo p = null;
            try { p = e.GetType().GetProperty(pn, BindingFlags.Instance | BindingFlags.Public | BindingFlags.FlattenHierarchy); }
            catch (AmbiguousMatchException) { p = e.GetType().GetProperties(BindingFlags.Instance | BindingFlags.Public).FirstOrDefault(x => x.Name == pn); }
            if (p == null || !p.CanRead || p.GetIndexParameters().Length > 0) continue;
            object v;
            try { v = p.GetValue(e); } catch { continue; }
            w.Key(pn);
            if (v is IEnumerable en && !(v is string))
            {
                w.BeginArray(); foreach (var x in en) w.Value(Convert.ToString(x, CultureInfo.InvariantCulture)); w.EndArray();
            }
            else WriteScalar(w, v);
        }
        w.EndObject();
    }

    static string Kebab(string camel)
    {
        var sb = new StringBuilder();
        foreach (char c in camel)
        {
            if (char.IsUpper(c)) { sb.Append('-'); sb.Append(char.ToLowerInvariant(c)); }
            else sb.Append(c);
        }
        var s = sb.ToString();
        if (s.StartsWith("unity-")) s = "-" + s;
        return s;
    }

    static void WriteResolved(JsonWriter w, VisualElement e)
    {
        w.BeginObject();
        var rs = e.resolvedStyle;
        foreach (var p in typeof(IResolvedStyle).GetProperties().OrderBy(x => x.Name, StringComparer.Ordinal))
        {
            object v;
            try { v = p.GetValue(rs); } catch { continue; }
            w.Key(Kebab(p.Name));
            WriteScalar(w, v);
        }
        // computedStyle-only values worth knowing.
        try
        {
            var csp = typeof(VisualElement).GetProperty("computedStyle", Any);
            object cs = csp != null ? csp.GetValue(e) : null;
            if (cs != null)
            {
                foreach (var n in new[] { "overflow", "cursor" })
                {
                    var f = cs.GetType().GetProperty(n, Any);
                    if (f == null) continue;
                    w.Key(n); WriteScalar(w, f.GetValue(cs));
                }
            }
        }
        catch { }
        w.EndObject();
    }

    static string Num(double d)
    {
        if (double.IsNaN(d)) return "NaN";
        return Math.Round(d, 4).ToString("R", CultureInfo.InvariantCulture);
    }

    static void WriteScalar(JsonWriter w, object v)
    {
        switch (v)
        {
            case null: w.Null(); return;
            case bool b: w.Value(b); return;
            case float f: w.Value(f); return;
            case double d: w.Value(d); return;
            case int i: w.Value(i); return;
            case string s: w.Value(s); return;
            case Color c:
                w.Value(string.Format(CultureInfo.InvariantCulture, "rgba({0}, {1}, {2}, {3})",
                    Num(c.r * 255.0), Num(c.g * 255.0), Num(c.b * 255.0), Num(c.a)));
                return;
            case Enum en: w.Value(Kebab(en.ToString()).TrimStart('-')); return;
            case StyleFloat sf: if (sf.keyword == StyleKeyword.Undefined) w.Value(sf.value); else w.Value(sf.keyword.ToString().ToLowerInvariant()); return;
            case StyleLength sl: w.Value(sl.keyword == StyleKeyword.Undefined ? sl.value.ToString() : sl.keyword.ToString().ToLowerInvariant()); return;
            case Background bg:
            {
                UnityEngine.Object o = bg.texture != null ? (UnityEngine.Object)bg.texture
                    : bg.sprite != null ? (UnityEngine.Object)bg.sprite
                    : bg.renderTexture != null ? (UnityEngine.Object)bg.renderTexture
                    : bg.vectorImage != null ? (UnityEngine.Object)bg.vectorImage : null;
                if (o == null) w.Null(); else w.Value(o.GetType().Name + ":" + o.name);
                return;
            }
            case UnityEngine.Object uo: w.Value(uo == null ? null : uo.GetType().Name + ":" + uo.name); return;
            case FontDefinition fd:
                if (fd.fontAsset != null) w.Value("FontAsset:" + fd.fontAsset.name);
                else if (fd.font != null) w.Value("Font:" + fd.font.name);
                else w.Null();
                return;
            case IEnumerable en2:
            {
                w.BeginArray(); foreach (var x in en2) WriteScalar(w, x); w.EndArray(); return;
            }
            default:
                w.Value(Convert.ToString(v, CultureInfo.InvariantCulture));
                return;
        }
    }

    // -----------------------------------------------------------------------

    class JsonWriter
    {
        readonly StringBuilder sb = new StringBuilder();
        readonly Stack<bool> first = new Stack<bool>();
        bool afterKey;
        int depth;

        void Sep()
        {
            if (afterKey) { afterKey = false; return; }
            if (first.Count > 0)
            {
                if (!first.Peek()) sb.Append(',');
                first.Pop(); first.Push(false);
                sb.Append('\n').Append(' ', depth);
            }
        }
        public void BeginObject() { Sep(); sb.Append('{'); first.Push(true); depth++; }
        public void EndObject() { depth--; bool empty = first.Pop(); if (!empty) sb.Append('\n').Append(' ', depth); sb.Append('}'); }
        public void BeginArray() { Sep(); sb.Append('['); first.Push(true); depth++; }
        public void EndArray() { depth--; bool empty = first.Pop(); if (!empty) sb.Append('\n').Append(' ', depth); sb.Append(']'); }
        public void Key(string k) { Sep(); Str(k); sb.Append(": "); afterKey = true; }
        public void Null() { Sep(); sb.Append("null"); }
        public void Value(bool b) { Sep(); sb.Append(b ? "true" : "false"); }
        public void Value(int i) { Sep(); sb.Append(i.ToString(CultureInfo.InvariantCulture)); }
        public void Value(double d)
        {
            Sep();
            if (double.IsNaN(d) || double.IsInfinity(d)) { sb.Append('"').Append(d.ToString(CultureInfo.InvariantCulture)).Append('"'); return; }
            sb.Append(Math.Round(d, 4).ToString("R", CultureInfo.InvariantCulture));
        }
        public void Value(string s) { Sep(); if (s == null) sb.Append("null"); else Str(s); }
        void Str(string s)
        {
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.AppendFormat(CultureInfo.InvariantCulture, "\\u{0:x4}", (int)c);
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }
        public override string ToString() { return sb.ToString() + "\n"; }
    }

    // Small JSON reader for the sidecar files.
    static class MiniJson
    {
        public static object Parse(string s) { int i = 0; return Read(s, ref i); }
        static void Ws(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }
        static object Read(string s, ref int i)
        {
            Ws(s, ref i);
            if (i >= s.Length) return null;
            char c = s[i];
            if (c == '{')
            {
                var d = new Dictionary<string, object>(); i++;
                Ws(s, ref i);
                if (s[i] == '}') { i++; return d; }
                while (true)
                {
                    Ws(s, ref i); string k = (string)Read(s, ref i); Ws(s, ref i); i++; // ':'
                    d[k] = Read(s, ref i); Ws(s, ref i);
                    if (s[i] == ',') { i++; continue; }
                    i++; return d;
                }
            }
            if (c == '[')
            {
                var l = new List<object>(); i++;
                Ws(s, ref i);
                if (s[i] == ']') { i++; return l; }
                while (true)
                {
                    l.Add(Read(s, ref i)); Ws(s, ref i);
                    if (s[i] == ',') { i++; continue; }
                    i++; return l;
                }
            }
            if (c == '"')
            {
                var sb = new StringBuilder(); i++;
                while (s[i] != '"')
                {
                    if (s[i] == '\\')
                    {
                        i++;
                        char e = s[i];
                        if (e == 'n') sb.Append('\n');
                        else if (e == 't') sb.Append('\t');
                        else if (e == 'u') { sb.Append((char)Convert.ToInt32(s.Substring(i + 1, 4), 16)); i += 4; }
                        else sb.Append(e);
                    }
                    else sb.Append(s[i]);
                    i++;
                }
                i++;
                return sb.ToString();
            }
            int st = i;
            while (i < s.Length && ",}] \t\r\n".IndexOf(s[i]) < 0) i++;
            string tok = s.Substring(st, i - st);
            if (tok == "true") return true;
            if (tok == "false") return false;
            if (tok == "null") return null;
            return double.Parse(tok, CultureInfo.InvariantCulture);
        }
    }
}
