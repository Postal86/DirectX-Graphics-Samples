//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************

#define HLSL
#include "RaytracingHlslCompat.h"
#include "RaytracingShaderHelper.hlsli"

Texture2D<float> g_inValues : register(t0);
Texture2D<float4> g_inNormal : register(t1);
Texture2D<float> g_inDepth : register(t2);
Texture2D<uint> g_inNormalOct : register(t3);
Texture2D<float> g_inVariance : register(t4);
Texture2D<float> g_inSmoothedVariance : register(t5);
RWTexture2D<float> g_outFilteredValues : register(u0);
RWTexture2D<float> g_outFilteredVariance : register(u1);
ConstantBuffer<AtrousWaveletTransformFilterConstantBuffer> cb: register(b0);

void AddFilterContribution(inout float weightedValueSum, inout float weightedVarianceSum, inout float weightSum, in float value, in float depth, in float3 normal, float obliqueness, in uint row, in uint col, in float w_h, in uint2 DTid)
{
    const float valueSigma = cb.valueSigma;
    const float normalSigma = cb.normalSigma;
    const float depthSigma = cb.depthSigma;

    int2 id = int2(DTid) + (int2(row - 1, col - 1) << cb.kernelStepShift);
    if (id.x >= 0 && id.y >= 0 && id.x < cb.textureDim.x && id.y < cb.textureDim.y)
    {
        float iValue = g_inValues[id];

        float iVariance;
        float w_x;
        if (cb.useCalculatedVariance)
        {
            iVariance = g_inSmoothedVariance[id];
            const float errorOffset = 0.005f;
            w_x = valueSigma > 0.01f ? exp(-abs(value - iValue) / (valueSigma * sqrt(max(iVariance, 0)) + errorOffset)) : 1;
        }
        else
        {
            w_x = valueSigma > 0.01f ? cb.kernelStepShift > 0 ? exp(-abs(value - iValue) / (valueSigma * valueSigma)) : 1 : 1;
        }


#if COMPRES_NORMALS
        float4 normalBufValue = g_inNormal[id];
        float4 normal4 = float4(Decode(normalBufValue.xy), normalBufValue.z);
#else
        float4 normal4 = g_inNormal[id];
#endif 
        float3 iNormal = normal4.xyz;

#if PACK_NORMAL_AND_DEPTH
        float iDepth = normal4.w;
#else
        float  iDepth = g_inDepth[id];
#endif
        float w_d = depthSigma > 0.01f ? exp(-abs(depth - iDepth) * obliqueness / (depthSigma * depthSigma)) : 1;
        // Ref: SVGF
        float w_n = normalSigma > 0.01f ? pow(max(0, dot(normal, iNormal)), normalSigma) : 1;

        float w = w_h * w_x * w_n * w_d;

        weightedValueSum += w * iValue;
        weightSum += w;

        if (cb.useCalculatedVariance)
        {
            weightedVarianceSum += w * w * iVariance;
        }
    }
}


// Atrous Wavelet Transform Cross Bilateral Filter
// Ref: Dammertz 2010, Edge-Avoiding A-Trous Wavelet Transform for Fast Global Illumination Filtering
[numthreads(AtrousWaveletTransformFilterCS::ThreadGroup::Width, AtrousWaveletTransformFilterCS::ThreadGroup::Height, 1)]
void main(uint2 DTid : SV_DispatchThreadID, uint2 Gid : SV_GroupID)
{
    const uint N = 3;
    const float kernel1D[N] = { 0.27901, 0.44198, 0.27901 };
    const float kernel[N][N] =
    {
        { kernel1D[0] * kernel1D[0], kernel1D[0] * kernel1D[1], kernel1D[0] * kernel1D[2] },
        { kernel1D[1] * kernel1D[0], kernel1D[1] * kernel1D[1], kernel1D[1] * kernel1D[2] },
        { kernel1D[2] * kernel1D[0], kernel1D[2] * kernel1D[1], kernel1D[2] * kernel1D[2] },
    };

#if COMPRES_NORMALS
    float4 normalBufValue = g_inNormal[DTid];
    float4 normal4 = float4(Decode(normalBufValue.xy), normalBufValue.z);
    float obliqueness = max(0.0001f, pow(normalBufValue.w, 10));
#else
    float4 normal4 = g_inNormal[DTid];
    #if PACK_NORMAL_AND_DEPTH
        float obliqueness = 1;
    #else
        float obliqueness = max(0.0001f, pow(normal4.w, 10));
    #endif
#endif
    float3 normal = normal4.xyz;

#if PACK_NORMAL_AND_DEPTH
    float depth = normal4.w;
#else
    float  depth = g_inDepth[DTid];
#endif

    float  value = g_inValues[DTid];

    float weightedValueSum = kernel[1][1] * value;
    float weightSum = kernel[1][1];
    float weightedVarianceSum = 0;
  
    if (cb.useCalculatedVariance)
    {
        weightedVarianceSum = kernel[1][1] * kernel[1][1] * g_inSmoothedVariance[DTid];
    }

#if 1
    AddFilterContribution(weightedValueSum, weightedVarianceSum, weightSum, value, depth, normal, obliqueness, 0, 0, kernel[0][0], DTid);
    AddFilterContribution(weightedValueSum, weightedVarianceSum, weightSum, value, depth, normal, obliqueness, 0, 1, kernel[0][1], DTid);
    AddFilterContribution(weightedValueSum, weightedVarianceSum, weightSum, value, depth, normal, obliqueness, 0, 2, kernel[0][2], DTid);
    AddFilterContribution(weightedValueSum, weightedVarianceSum, weightSum, value, depth, normal, obliqueness, 1, 0, kernel[1][0], DTid);
    AddFilterContribution(weightedValueSum, weightedVarianceSum, weightSum, value, depth, normal, obliqueness, 1, 2, kernel[1][2], DTid);
    AddFilterContribution(weightedValueSum, weightedVarianceSum, weightSum, value, depth, normal, obliqueness, 2, 0, kernel[2][0], DTid);
    AddFilterContribution(weightedValueSum, weightedVarianceSum, weightSum, value, depth, normal, obliqueness, 2, 1, kernel[2][1], DTid);
    AddFilterContribution(weightedValueSum, weightedVarianceSum, weightSum, value, depth, normal, obliqueness, 2, 2, kernel[2][2], DTid);
#endif

    g_outFilteredValues[DTid] = weightSum > 0.0001f ? weightedValueSum / weightSum : 0.f;

    if (cb.useCalculatedVariance)
    {
        g_outFilteredVariance[DTid] = weightSum > 0.0001f ? weightedVarianceSum / (weightSum * weightSum) : 0.f;
    }
}