// A UI Toolkit material for the -unity-material pixel case: Unity's
// standard UI Toolkit vertex and fragment functions (UnityUIE.cginc), then
// one colour operation. The tag isCustomUITKShader makes UI Toolkit accept
// it. The Godot equivalent is Tint.tres beside it.
Shader "UxmlDump/Tint"
{
    Properties
    {
        _Tint ("Tint", Color) = (1, 1, 1, 1)
    }
    SubShader
    {
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent" "IgnoreProjector" = "True" "PreviewType" = "Plane" "isCustomUITKShader" = "true" }
        Cull Off
        ZWrite Off
        ZTest Always
        Blend SrcAlpha OneMinusSrcAlpha, One OneMinusSrcAlpha
        Pass
        {
            CGPROGRAM
            #pragma target 3.5
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_local _ _UIE_FORCE_GAMMA
            #pragma multi_compile_local _ _UIE_TEXTURE_SLOT_COUNT_4 _UIE_TEXTURE_SLOT_COUNT_2 _UIE_TEXTURE_SLOT_COUNT_1
            #pragma multi_compile_local _ _UIE_RENDER_TYPE_SOLID _UIE_RENDER_TYPE_TEXTURE _UIE_RENDER_TYPE_TEXT _UIE_RENDER_TYPE_GRADIENT
            #include "Internal/UnityUIE.cginc"
            fixed4 _Tint;
            v2f vert(appdata_t v) { return uie_std_vert(v); }
            UIE_FRAG_T frag(v2f IN) : SV_Target
            {
                UIE_FRAG_T c = uie_std_frag(IN);
                c.rgb *= _Tint.rgb;
                return c;
            }
            ENDCG
        }
    }
}
