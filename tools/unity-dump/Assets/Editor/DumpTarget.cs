// A ScriptableObject that the editor cases bind to ("bind": "DumpTarget"
// in a case sidecar): PropertyField and InspectorElement build their
// fields from its serialized properties.
using System;
using UnityEngine;

public enum DumpEnum { First, SecondValue, Third }

[Flags]
public enum DumpFlags { None = 0, Alpha = 1, Beta = 2, Gamma = 4, AlphaBeta = 3 }

public class DumpTarget : ScriptableObject
{
    public int intValue = 42;
    public float floatValue = 1.5f;
    public string stringValue = "hello";
    public bool boolValue = true;
    public Color colorValue = new Color(1f, 0.5f, 0f, 1f);
    public Vector2 vector2Value = new Vector2(1, 2);
    public Vector3 vector3Value = new Vector3(1, 2, 3);
    public DumpEnum enumValue = DumpEnum.SecondValue;
    public DumpFlags flagsValue = DumpFlags.Alpha | DumpFlags.Gamma;
    public AnimationCurve curveValue = AnimationCurve.Linear(0, 0, 1, 1);
    public Gradient gradientValue = new Gradient();
    public Texture2D textureValue;
    public LayerMask layerMaskValue = 1;
}
