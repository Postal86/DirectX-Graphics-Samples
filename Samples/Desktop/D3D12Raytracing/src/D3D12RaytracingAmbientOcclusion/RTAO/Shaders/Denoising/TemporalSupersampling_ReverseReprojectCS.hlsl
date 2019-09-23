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

// ToDo Desc
// Desc: Sample temporal cache via reverse reprojection.
// If no valid values have been retrieved from the cache, the tspp is set to 0.

#define HLSL
#include "RaytracingHlslCompat.h"
#include "RaytracingShaderHelper.hlsli"
#include "RTAO\Shaders\RTAO.hlsli"
#include "CrossBilateralWeights.hlsli"

// ToDo some pixels here and there on mirror boundaries fail temporal reprojection even for static scene/camera
// ToDo sharp edges fail temporal reprojection due to clamping even for static scene
Texture2D<NormalDepthTexFormat> g_inCurrentFrameNormalDepth : register(t0);
Texture2D<float2> g_inCurrentFrameLinearDepthDerivative : register(t1);
Texture2D<NormalDepthTexFormat> g_inReprojectedNormalDepth : register(t2); 
Texture2D<float2> g_inTextureSpaceMotionVector : register(t3);
Texture2D<NormalDepthTexFormat> g_inCachedNormalDepth : register(t4);
Texture2D<float> g_inCachedValue : register(t5);
Texture2D<uint2> g_inCachedTspp : register(t6);
Texture2D<float> g_inCachedValueSquaredMean : register(t7);
Texture2D<float> g_inCachedRayHitDepth : register(t8);


RWTexture2D<uint> g_outCachedTspp : register(u0);
RWTexture2D<uint4> g_outReprojectedCachedValues : register(u1);

RWTexture2D<float4> g_outDebug1 : register(u10);
RWTexture2D<float4> g_outDebug2 : register(u11);

ConstantBuffer<TemporalSupersampling_ReverseReprojectConstantBuffer> cb : register(b0);
SamplerState ClampSampler : register(s0);

// ToDo
// Optimizations:
//  - condition to only necessary reads on tspp 1 and/or invalid value
//  - on 0 motion vector read in only 1 cached value

// Calculates a depth threshold for surface at angle beta from camera plane
// based on threshold for a surface at angle alpha
float CalculateAdjustedDepthThreshold(
    float d1,       // ddxy for surface at angle alpha from camera plane
    float alpha,    // angle in radians for surface with threshold d1 
    float beta,     // angle in radians for target surface
    float rho)      // view angle for the pixel
{
    // ToDo add derivation comment
    return d1
        * (sin(beta) / sin(alpha))
        * (cos(rho + alpha) / cos(rho + beta));

}

float CalculateAdjustedDepthThreshold(
    float d,            // ddxy for surface with normal
    float z,            // Linear depth for current frame
    float _z,           // Linear depth for prev frame
    float3 normal,      // normal for a surface with threshold d 
    float3 _normal)     // normal of a target surface
{
    float _d = d * _z / z;


    float3 forwardRay = GenerateForwardCameraRayDirection(cb.projectionToView);
    float3 _forwardRay = GenerateForwardCameraRayDirection(cb.prevProjectionToWorldWithCameraEyeAtOrigin);

    float alpha = acos(dot(normal, forwardRay));
    float beta = acos(dot(_normal, _forwardRay));

    float rho = (FOVY * PI / 180) * cb.invTextureDim.y;

    return CalculateAdjustedDepthThreshold(_d, alpha, beta, rho);
}


float4 BilateralResampleWeights(in float TargetDepth, in float3 TargetNormal, in float4 SampleDepths, in float3 SampleNormals[4], in float2 TargetOffset, in uint2 TargetIndex, in int2 sampleIndices[4], in float2 Ddxy)
{
    bool4 isWithinBounds = bool4(
        IsWithinBounds(sampleIndices[0], cb.textureDim),
        IsWithinBounds(sampleIndices[1], cb.textureDim),
        IsWithinBounds(sampleIndices[2], cb.textureDim),
        IsWithinBounds(sampleIndices[3], cb.textureDim));
 
    CrossBilateral::BilinearDepthNormal::Parameters params;
    params.Depth.Sigma = cb.depthSigma;
    params.Depth.WeightCutoff = 0.5;// ToDo pass from cb cb.DepthWeightCutoff;
    params.Depth.NumMantissaBits = cb.DepthNumMantissaBits;
    params.Normal.Sigma = 1.1;      // Bump the sigma a bit to add tolerance for slight geometry misalignments and/or format precision limitations.
    params.Normal.SigmaExponent = 32; // ToDo pass from cb

    float4 bilinearDepthNormalWeights;

    if (cb.usingBilateralDownsampledBuffers)
    {
        // Account for 0.5 sample offset in bilateral downsampled partial depth derivative buffer.
        // Since both target and the samples can be offseted by up to 0.5 the higher resolution, 
        // they add up to total 0.5 sample offset in the lower resolution.
        float2 samplesOffset = float2(1.5, 1.5);

        bilinearDepthNormalWeights = CrossBilateral::BilinearDepthNormal::GetWeights(
            TargetDepth,
            TargetNormal,
            TargetOffset,
            Ddxy,
            SampleDepths,
            SampleNormals,
            samplesOffset,
            params);
    }
    else
    {
        bilinearDepthNormalWeights = CrossBilateral::BilinearDepthNormal::GetWeights(
            TargetDepth,
            TargetNormal,
            TargetOffset,
            Ddxy,
            SampleDepths,
            SampleNormals,
            params);
    }

    float4 weights = isWithinBounds * bilinearDepthNormalWeights;

    return weights;
}


[numthreads(DefaultComputeShaderParams::ThreadGroup::Width, DefaultComputeShaderParams::ThreadGroup::Height, 1)]
void main(uint2 DTid : SV_DispatchThreadID)
{
    float3 _normal;
    float _depth;
    DecodeNormalDepth(g_inReprojectedNormalDepth[DTid], _normal, _depth);
    float2 textureSpaceMotionVector = g_inTextureSpaceMotionVector[DTid];

    if (_depth == 0 || textureSpaceMotionVector.x > 1e2f)
    {
        g_outCachedTspp[DTid] = 0;
        return;
    }

    float2 texturePos = (DTid.xy + 0.5f) * cb.invTextureDim;
    float2 cacheFrameTexturePos = texturePos - textureSpaceMotionVector;

    // Find the nearest integer index smaller than the texture position.
    // The floor() ensures the that value sign is taken into consideration.
    int2 topLeftCacheFrameIndex = floor(cacheFrameTexturePos * cb.textureDim - 0.5);
    float2 adjustedCacheFrameTexturePos = (topLeftCacheFrameIndex + 0.5) * cb.invTextureDim;

    float2 cachePixelOffset = cacheFrameTexturePos * cb.textureDim - 0.5 - topLeftCacheFrameIndex;

    const int2 srcIndexOffsets[4] = { {0, 0}, {1, 0}, {0, 1}, {1, 1} };

    int2 cacheIndices[4] = {
        topLeftCacheFrameIndex + srcIndexOffsets[0],
        topLeftCacheFrameIndex + srcIndexOffsets[1],
        topLeftCacheFrameIndex + srcIndexOffsets[2],
        topLeftCacheFrameIndex + srcIndexOffsets[3] };

    float3 cacheNormals[4];
    float4 vCacheDepths;
    {
        uint4 packedEncodedNormalDepths = g_inCachedNormalDepth.GatherRed(ClampSampler, adjustedCacheFrameTexturePos).wzxy;
        [unroll]
        for (int i = 0; i < 4; i++)
        {
            DecodeNormalDepth(packedEncodedNormalDepths[i], cacheNormals[i], vCacheDepths[i]);
        }
    }

    float2 ddxy = g_inCurrentFrameLinearDepthDerivative[DTid];
    
    float4 weights;
    weights = BilateralResampleWeights(_depth, _normal, vCacheDepths, cacheNormals, cachePixelOffset, DTid, cacheIndices, ddxy);
    
    // Invalidate weights for invalid values in the cache.
    float4 vCacheValues = g_inCachedValue.GatherRed(ClampSampler, adjustedCacheFrameTexturePos).wzxy;
    weights = vCacheValues != RTAO::InvalidAOCoefficientValue ? weights : 0;
    float weightSum = dot(1, weights);
    
    float cachedValue = RTAO::InvalidAOCoefficientValue;
    float cachedValueSquaredMean = 0;
    float cachedRayHitDepth = 0;

    uint tspp;
    bool areCacheValuesValid = weightSum > 1e-3f;
    if (areCacheValuesValid)
    {
        uint4 vCachedTspp = g_inCachedTspp.GatherRed(ClampSampler, adjustedCacheFrameTexturePos).wzxy;
        // Enforce tspp of at least 1 for reprojection for valid values.
        // This is because the denoiser will fill in invalid values with filtered 
        // ones if it can. But it doesn't increase tspp.
        vCachedTspp = max(1, vCachedTspp);


        float4 nWeights = weights / weightSum;   // Normalize the weights.

       // g_outDebug1[DTid] = float4(weights.xyz, weightSum);
       // g_outDebug2[DTid] = nWeights;

        // ToDo revisit this and potentially make it UI adjustable - weight ^ 2 ?,...
        // Scale the tspp by the total weight. This is to keep the tspp low for 
        // total contributions that have very low reprojection weight. While its preferred to get 
        // a weighted value even for reprojections that have low weights but still
        // satisfy consistency tests, the tspp needs to be kept small so that the Target calculated values
        // are quickly filled in over a few frames. Otherwise, bad estimates from reprojections,
        // such as on disocclussions of surfaces on rotation, are kept around long enough to create 
        // visible streaks that fade away very slow.
        // Example: rotating camera around dragon's nose up close. 
        float TsppScale = 1;// saturate(weightSum); // ToDo

        float cachedTspp = TsppScale * dot(nWeights, vCachedTspp);
        tspp = round(cachedTspp);
        
        if (tspp > 0)
        {
            float4 vCacheValues = g_inCachedValue.GatherRed(ClampSampler, adjustedCacheFrameTexturePos).wzxy;
            cachedValue = dot(nWeights, vCacheValues);

            float4 vCachedValueSquaredMean = g_inCachedValueSquaredMean.GatherRed(ClampSampler, adjustedCacheFrameTexturePos).wzxy;
            cachedValueSquaredMean = dot(nWeights, vCachedValueSquaredMean);

            float4 vCachedRayHitDepths = g_inCachedRayHitDepth.GatherRed(ClampSampler, adjustedCacheFrameTexturePos).wzxy;
            cachedRayHitDepth = dot(nWeights, vCachedRayHitDepths);
            g_outDebug1[DTid] = nWeights;
            g_outDebug1[DTid] = vCachedRayHitDepths;
        }

    }
    else
    {
        // No valid values can be retrieved from the cache.
        tspp = 0;
    }
    g_outCachedTspp[DTid] = tspp;
    g_outReprojectedCachedValues[DTid] = uint4(tspp, f32tof16(float3(cachedValue, cachedValueSquaredMean, cachedRayHitDepth)));
}