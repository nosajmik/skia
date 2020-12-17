#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;
struct Inputs {
    float4 src;
    float4 dst;
};
struct Outputs {
    float4 sk_FragColor [[color(0)]];
};
float _blend_overlay_component(float2 s, float2 d) {
    return 2.0 * d.x <= d.y ? (2.0 * s.x) * d.x : s.y * d.y - (2.0 * (d.y - d.x)) * (s.y - s.x);
}
float4 blend_overlay(float4 src, float4 dst) {
    float4 result = float4(_blend_overlay_component(src.xw, dst.xw), _blend_overlay_component(src.yw, dst.yw), _blend_overlay_component(src.zw, dst.zw), src.w + (1.0 - src.w) * dst.w);
    result.xyz = result.xyz + dst.xyz * (1.0 - src.w) + src.xyz * (1.0 - dst.w);
    return result;
}
float _color_dodge_component(float2 s, float2 d) {
    if (d.x == 0.0) {
        return s.x * (1.0 - d.y);
    } else {
        float delta = s.y - s.x;
        if (delta == 0.0) {
            return (s.y * d.y + s.x * (1.0 - d.y)) + d.x * (1.0 - s.y);
        } else {
            float _4_n = d.x * s.y;
            delta = min(d.y, _4_n / delta);

            return (delta * s.y + s.x * (1.0 - d.y)) + d.x * (1.0 - s.y);
        }
    }
}
float _color_burn_component(float2 s, float2 d) {
    if (d.y == d.x) {
        return (s.y * d.y + s.x * (1.0 - d.y)) + d.x * (1.0 - s.y);
    } else if (s.x == 0.0) {
        return d.x * (1.0 - s.y);
    } else {
        float _6_n = (d.y - d.x) * s.y;
        float delta = max(0.0, d.y - _6_n / s.x);

        return (delta * s.y + s.x * (1.0 - d.y)) + d.x * (1.0 - s.y);
    }
}
float _soft_light_component(float2 s, float2 d) {
    if (2.0 * s.x <= s.y) {
        float _8_n = (d.x * d.x) * (s.y - 2.0 * s.x);
        return (_8_n / d.y + (1.0 - d.y) * s.x) + d.x * ((-s.y + 2.0 * s.x) + 1.0);

    } else if (4.0 * d.x <= d.y) {
        float DSqd = d.x * d.x;
        float DCub = DSqd * d.x;
        float DaSqd = d.y * d.y;
        float DaCub = DaSqd * d.y;
        float _10_n = ((DaSqd * (s.x - d.x * ((3.0 * s.y - 6.0 * s.x) - 1.0)) + ((12.0 * d.y) * DSqd) * (s.y - 2.0 * s.x)) - (16.0 * DCub) * (s.y - 2.0 * s.x)) - DaCub * s.x;
        return _10_n / DaSqd;

    } else {
        return ((d.x * ((s.y - 2.0 * s.x) + 1.0) + s.x) - sqrt(d.y * d.x) * (s.y - 2.0 * s.x)) - d.y * s.x;
    }
}
float3 _blend_set_color_luminance(float3 hueSatColor, float alpha, float3 lumColor) {
    float lum = dot(float3(0.30000001192092896, 0.5899999737739563, 0.10999999940395355), lumColor);

    float3 result = (lum - dot(float3(0.30000001192092896, 0.5899999737739563, 0.10999999940395355), hueSatColor)) + hueSatColor;

    float minComp = min(min(result.x, result.y), result.z);
    float maxComp = max(max(result.x, result.y), result.z);
    if (minComp < 0.0 && lum != minComp) {
        result = lum + ((result - lum) * lum) / (lum - minComp);
    }
    return maxComp > alpha && maxComp != lum ? lum + ((result - lum) * (alpha - lum)) / (maxComp - lum) : result;
}
float3 _blend_set_color_saturation_helper(float3 minMidMax, float sat) {
    return minMidMax.x < minMidMax.z ? float3(0.0, (sat * (minMidMax.y - minMidMax.x)) / (minMidMax.z - minMidMax.x), sat) : float3(0.0);
}
float3 _blend_set_color_saturation(float3 hueLumColor, float3 satColor) {
    float sat = max(max(satColor.x, satColor.y), satColor.z) - min(min(satColor.x, satColor.y), satColor.z);

    if (hueLumColor.x <= hueLumColor.y) {
        if (hueLumColor.y <= hueLumColor.z) {
            return _blend_set_color_saturation_helper(hueLumColor, sat);
        } else if (hueLumColor.x <= hueLumColor.z) {
            return _blend_set_color_saturation_helper(hueLumColor.xzy, sat).xzy;
        } else {
            return _blend_set_color_saturation_helper(hueLumColor.zxy, sat).yzx;
        }
    } else if (hueLumColor.x <= hueLumColor.z) {
        return _blend_set_color_saturation_helper(hueLumColor.yxz, sat).yxz;
    } else if (hueLumColor.y <= hueLumColor.z) {
        return _blend_set_color_saturation_helper(hueLumColor.yzx, sat).zxy;
    } else {
        return _blend_set_color_saturation_helper(hueLumColor.zyx, sat).zyx;
    }
}
float4 blend(int mode, float4 src, float4 dst) {
    switch (mode) {
        case 0:
            return float4(0.0);

        case 1:
            return src;

        case 2:
            return dst;

        case 3:
            return src + (1.0 - src.w) * dst;

        case 4:
            return (1.0 - dst.w) * src + dst;

        case 5:
            return src * dst.w;

        case 6:
            return dst * src.w;

        case 7:
            return (1.0 - dst.w) * src;

        case 8:
            return (1.0 - src.w) * dst;

        case 9:
            return dst.w * src + (1.0 - src.w) * dst;

        case 10:
            return (1.0 - dst.w) * src + src.w * dst;

        case 11:
            return (1.0 - dst.w) * src + (1.0 - src.w) * dst;

        case 12:
            return min(src + dst, 1.0);

        case 13:
            return src * dst;

        case 14:
            return src + (1.0 - src) * dst;

        case 15:
            return blend_overlay(src, dst);
        case 16:
            float4 _32_result = src + (1.0 - src.w) * dst;

            _32_result.xyz = min(_32_result.xyz, (1.0 - dst.w) * src.xyz + dst.xyz);
            return _32_result;

        case 17:
            float4 _35_result = src + (1.0 - src.w) * dst;

            _35_result.xyz = max(_35_result.xyz, (1.0 - dst.w) * src.xyz + dst.xyz);
            return _35_result;

        case 18:
            return float4(_color_dodge_component(src.xw, dst.xw), _color_dodge_component(src.yw, dst.yw), _color_dodge_component(src.zw, dst.zw), src.w + (1.0 - src.w) * dst.w);

        case 19:
            return float4(_color_burn_component(src.xw, dst.xw), _color_burn_component(src.yw, dst.yw), _color_burn_component(src.zw, dst.zw), src.w + (1.0 - src.w) * dst.w);

        case 20:
            return blend_overlay(dst, src);

        case 21:
            return dst.w == 0.0 ? src : float4(_soft_light_component(src.xw, dst.xw), _soft_light_component(src.yw, dst.yw), _soft_light_component(src.zw, dst.zw), src.w + (1.0 - src.w) * dst.w);

        case 22:
            return float4((src.xyz + dst.xyz) - 2.0 * min(src.xyz * dst.w, dst.xyz * src.w), src.w + (1.0 - src.w) * dst.w);

        case 23:
            return float4((dst.xyz + src.xyz) - (2.0 * dst.xyz) * src.xyz, src.w + (1.0 - src.w) * dst.w);

        case 24:
            return float4(((1.0 - src.w) * dst.xyz + (1.0 - dst.w) * src.xyz) + src.xyz * dst.xyz, src.w + (1.0 - src.w) * dst.w);

        case 25:
            float _44_alpha = dst.w * src.w;
            float3 _45_sda = src.xyz * dst.w;
            float3 _46_dsa = dst.xyz * src.w;
            return float4((((_blend_set_color_luminance(_blend_set_color_saturation(_45_sda, _46_dsa), _44_alpha, _46_dsa) + dst.xyz) - _46_dsa) + src.xyz) - _45_sda, (src.w + dst.w) - _44_alpha);

        case 26:
            float _48_alpha = dst.w * src.w;
            float3 _49_sda = src.xyz * dst.w;
            float3 _50_dsa = dst.xyz * src.w;
            return float4((((_blend_set_color_luminance(_blend_set_color_saturation(_50_dsa, _49_sda), _48_alpha, _50_dsa) + dst.xyz) - _50_dsa) + src.xyz) - _49_sda, (src.w + dst.w) - _48_alpha);

        case 27:
            float _52_alpha = dst.w * src.w;
            float3 _53_sda = src.xyz * dst.w;
            float3 _54_dsa = dst.xyz * src.w;
            return float4((((_blend_set_color_luminance(_53_sda, _52_alpha, _54_dsa) + dst.xyz) - _54_dsa) + src.xyz) - _53_sda, (src.w + dst.w) - _52_alpha);

        case 28:
            float _56_alpha = dst.w * src.w;
            float3 _57_sda = src.xyz * dst.w;
            float3 _58_dsa = dst.xyz * src.w;
            return float4((((_blend_set_color_luminance(_58_dsa, _56_alpha, _57_sda) + dst.xyz) - _58_dsa) + src.xyz) - _57_sda, (src.w + dst.w) - _56_alpha);

    }
    return float4(0.0);
}


fragment Outputs fragmentMain(Inputs _in [[stage_in]], bool _frontFacing [[front_facing]], float4 _fragCoord [[position]]) {
    Outputs _outputStruct;
    thread Outputs* _out = &_outputStruct;
    _out->sk_FragColor = blend(13, _in.src, _in.dst);
    return *_out;
}
