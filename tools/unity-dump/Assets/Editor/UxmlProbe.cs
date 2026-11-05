// Unity ground truth for godot-uxml control behaviour that a layout dump
// cannot show: how the numeric fields parse and format text (expressions
// included). Writes bench/parity/probes/numeric.json.
//
//   Unity.exe -batchmode -projectPath tools/unity-dump
//     -executeMethod UxmlProbe.Run -probeOut <file> -logFile <log>
//
// Each record: field type, initial value, input text, the value that
// StringToValue returns (the field's own commit path), and that value as
// the field formats it.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

public static class UxmlProbe
{
    const BindingFlags Any = BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;

    static readonly string[] Inputs = {
        "2*3", "7/2", "10/3", "-5", "1+2*3", "(1+2)*3", "2^10", "2^3^2", "+=5", "-=3", "*=2", "/=4",
        "sqrt(16)", "sqrt(-4)", "floor(2.7)", "ceil(2.1)", "round(2.5)", "round(3.5)", "abc", "", " 42 ",
        "1,5", "3.7", "-3.7", "2.5", "-2.5", "1e3", "inf", "-inf", "nan", "pi", "PI", "x+1", "2*", "1/0", "-1/0",
        "10%3", "-10%3", "-(2+3)", "2^-1", "99999999999", "-99999999999", "1/3*3", "0.1+0.2",
        "L(0,10)", "5f", "5d", "5l", "sin(0)", "cos(0)", "3 4", "4-", "--2", "2--2", "0x10", "#", "v*2",
        "1.5e-3", "12345678.9", "0.000001", "1e40", "-1e40", "1e300*1e300", "4294967296", "-1",
        "18446744073709551615", "9223372036854775807", "9223372036854775808",
    };

    static string Arg(string name, string fallback)
    {
        var args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == name) return args[i + 1];
        return fallback;
    }

    static string Str(object v)
    {
        if (v is float f) return f.ToString("R", CultureInfo.InvariantCulture);
        if (v is double d) return d.ToString("R", CultureInfo.InvariantCulture);
        return Convert.ToString(v, CultureInfo.InvariantCulture);
    }

    static string Esc(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (char c in s)
        {
            if (c == '"' || c == '\\') sb.Append('\\').Append(c);
            else if (c < 0x20) sb.AppendFormat("\\u{0:x4}", (int)c);
            else sb.Append(c);
        }
        return sb.Append('"').ToString();
    }

    static void Probe<T>(BaseField<T> field, T initial, string type, string[] inputs, List<string> rows)
    {
        var stv = field.GetType().GetMethod("StringToValue", Any, null, new[] { typeof(string) }, null);
        var vts = field.GetType().GetMethod("ValueToString", Any, null, new[] { typeof(T) }, null);
        var te = field.Q<TextElement>();
        var orig = typeof(TextElement).GetField("m_OriginalText", Any);
        foreach (var input in inputs)
        {
            field.SetValueWithoutNotify(initial);
            var shown = (string)vts.Invoke(field, new object[] { initial });
            if (orig != null && te != null) orig.SetValue(te, shown);
            string result, formatted;
            try
            {
                var v = stv.Invoke(field, new object[] { input });
                result = Str(v);
                formatted = (string)vts.Invoke(field, new object[] { v });
            }
            catch (Exception e)
            {
                result = "exception: " + (e.InnerException ?? e).GetType().Name;
                formatted = "";
            }
            rows.Add(string.Format("{{\"type\": {0}, \"initial\": {1}, \"input\": {2}, \"value\": {3}, \"text\": {4}}}",
                Esc(type), Esc(shown), Esc(input), Esc(result), Esc(formatted)));
        }
    }

    static void Format<T>(BaseField<T> field, string type, T[] values, List<string> rows)
    {
        var vts = field.GetType().GetMethod("ValueToString", Any, null, new[] { typeof(T) }, null);
        foreach (var v in values)
            rows.Add(string.Format("{{\"type\": {0}, \"format\": {1}, \"text\": {2}}}",
                Esc(type), Esc(Str(v)), Esc((string)vts.Invoke(field, new object[] { v }))));
    }

    public static void Run()
    {
        int exit = 0;
        try
        {
            var rows = new List<string>();
            Probe(new IntegerField(), 10, "IntegerField", Inputs, rows);
            Probe(new LongField(), 10L, "LongField", Inputs, rows);
            Probe(new FloatField(), 1.5f, "FloatField", Inputs, rows);
            Probe(new DoubleField(), 1.5, "DoubleField", Inputs, rows);
            Probe(new UnsignedIntegerField(), 10u, "UnsignedIntegerField", Inputs, rows);
            Probe(new UnsignedLongField(), 10ul, "UnsignedLongField", Inputs, rows);
            Probe(new Hash128Field(), new Hash128(), "Hash128Field", new[] {
                "0123456789abcdef0123456789abcdef", "ABCDEF", "abc", "", "xyz", "1", "00000000000000000000000000000001",
                "0123456789abcdef0123456789abcdef0", "fedcba98765432100123456789abcdef", "12345678 9abc" }, rows);
            Format(new FloatField(), "FloatField", new[] { 0.1f, 1f / 3f, 1e10f, 123456789f, -0f, 1e-5f, 2.5f, 100f, 1234567f, 12345678f,
                float.PositiveInfinity, float.NegativeInfinity, float.NaN, 0.000123456f, 3.14159265f }, rows);
            Format(new DoubleField(), "DoubleField", new[] { 0.1, 1.0 / 3.0, 1e21, 123456789.123, 1e-7, 2.5, 100.0, 0.1 + 0.2,
                double.PositiveInfinity, double.NaN, 1e15, 1e16, 123456789012345678.0 }, rows);
            Format(new IntegerField(), "IntegerField", new[] { 0, -5, 1234567, int.MaxValue, int.MinValue }, rows);
            var path = Arg("-probeOut", "numeric.json");
            File.WriteAllText(path, "{\n \"unityVersion\": " + Esc(Application.unityVersion) + ",\n \"rows\": [\n  "
                + string.Join(",\n  ", rows) + "\n ]\n}\n", new UTF8Encoding(false));
            Debug.Log("[uxml-probe] wrote " + rows.Count + " rows to " + path);
        }
        catch (Exception e)
        {
            exit = 1;
            Debug.LogError("[uxml-probe] " + e);
        }
        EditorApplication.Exit(exit);
    }
}
