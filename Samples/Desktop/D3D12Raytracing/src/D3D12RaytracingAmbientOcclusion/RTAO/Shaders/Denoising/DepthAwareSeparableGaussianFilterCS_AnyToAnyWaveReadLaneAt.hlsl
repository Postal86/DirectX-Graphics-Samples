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

// ToDo
// Desc: Filters invalid values from neighborhood via gaussian filter.
// Supports up to 9x9 kernels.
// Requirements:
// - wave lane size 16 or higher.
// Performance: 
// ToDo:

#define HLSL
#include "RaytracingHlslCompat.h"
#include "RaytracingShaderHelper.hlsli"
#include "RTAO/Shaders/RTAO.hlsli"

#define GAUSSIAN_KERNEL_5X5
#include "Kernels.hlsli"

Texture2D<float> g_inValues : register(t0);
Texture2D<NormalDepthTexFormat> g_inNormalDepth : register(t1);
RWTexture2D<float> g_outValues : register(u0);

ConstantBuffer<FilterConstantBuffer> cb: register(b0);

// Group shared memory cache for the row aggregated results.
groupshared uint PackedValuesDepthsCache[16][8];         // 16bit float value, depth.
groupshared uint PackedRowResultCache[16][8];            // 16bit float weightedValueSum, weightSum.

uint2 GetPixelIndex(in uint2 Gid, in uint2 GTid)
{
    // Find a DTID with steps in between the group threads and groups interleaved to cover all pixels.
    uint2 GroupDim = uint2(DefaultComputeShaderParams::ThreadGroup::Width, DefaultComputeShaderParams::ThreadGroup::Height);
    uint2 groupBase = (Gid / cb.step) * cb.step * GroupDim + Gid % cb.step;
    uint2 groupThreadOffset = GTid * cb.step;
    uint2 sDTid = groupBase + groupThreadOffset;

    return sDTid;
}

// Load up to 16x16 pixels and filter them horizontally.
// The output is cached in Shared Memory and contains NumRows x 8 results.
void FilterHorizontally(in uint2 Gid, in uint GI)
{
    const uint2 GroupDim = uint2(8, 8);
    const uint NumValuesToLoadPerRowOrColumn = GroupDim.x + (FilterKernel::Width - 1);

    // Process the thread group as row-major 16x4, where each sub group of 16 threads processes one row.
    // Each thread loads up to 4 values, with the sub groups loading rows interleaved.
    // Loads up to 16x4x4 == 256 input values.
    uint2 GTid16x4_row0 = uint2(GI % 16, GI / 16);
    int2 KernelBasePixel = GetPixelIndex(Gid, 0) - int2(FilterKernel::Radius, FilterKernel::Radius) * cb.step;
    const uint NumRowsToLoadPerThread = 4;
    const uint Row_BaseWaveLaneIndex = (WaveGetLaneIndex() / 16) * 16;

    // ToDo load 8x8 center values to cache and skip if none of the values are missing.
    // ToDo blend low frame age values too with a falloff?

    [unroll]
    for (uint i = 0; i < NumRowsToLoadPerThread; i++)
    {
        uint2 GTid16x4 = GTid16x4_row0 + uint2(0, i * 4);
        if (GTid16x4.y >= NumValuesToLoadPerRowOrColumn)
        {
            break;
        }

        // Load all the contributing columns for each row.
        int2 pixel = KernelBasePixel + GTid16x4 * cb.step;
        float value = RTAO::InvalidAOValue;
        float depth = 0;

        // The lane is out of bounds of the GroupDim + kernel, 
        // but could be within bounds of the input texture,
        // so don't read it from the texture.
        // but need to keep it as an active lane for a below split sum.
        if (GTid16x4.x < NumValuesToLoadPerRowOrColumn && IsWithinBounds(pixel, cb.textureDim))
        {
            value = g_inValues[pixel];
            
            // ToDo remove normal if not needed.
            float3 dummyNormal;
            DecodeNormalDepth(g_inNormalDepth[pixel], dummyNormal, depth);
        }

        if (IsInRange(GTid16x4.x, FilterKernel::Radius, FilterKernel::Radius + GroupDim.x - 1))
        {
            PackedValuesDepthsCache[GTid16x4.y][GTid16x4.x - FilterKernel::Radius] = Float2ToHalf(float2(value, depth));
        }

        // Filter the values for the first GroupDim columns.
        {
            // Accumulate for the whole kernel width.
            float weightedValueSum = 0;
            float weightSum = 0;

            // Since a row uses 16 lanes, but we only need to calculate the aggregate for the first half (8) lanes,
            // split the kernel wide aggregation among the first 8 and the second 8 lanes, and then combine them.

            // Initialize the first 8 lanes to the center cell contribution of the kernel. 
            // This covers the remainder of 1 in FilterKernel::Width / 2 used in the loop below. 
            if (GTid16x4.x < GroupDim.x && value != RTAO::InvalidAOValue && depth != 0)
            {
                float w = FilterKernel::Kernel1D[FilterKernel::Radius];
                weightedValueSum = w * abs(value);
                weightSum = w;
            }

            uint KernelCellIndexStart =       
                GTid16x4.x < GroupDim.x
                    ? 0
                    : FilterKernel::Radius + 1; // Skip over the already accumulated center cell of the kernel.

            uint Row_ThreadStartLaneIndex =
                Row_BaseWaveLaneIndex
                + KernelCellIndexStart     
                + GTid16x4.x < GroupDim.x
                    ? GTid16x4.x
                    : (GTid16x4.x - GroupDim.x);

            // For all columns in the kernel.
            for (uint c = 0; c < FilterKernel::Radius; c++)
            {
                uint laneToReadFrom = Row_ThreadStartLaneIndex + c;

                float cValue = WaveReadLaneAt(value, laneToReadFrom);
                float cDepth = WaveReadLaneAt(depth, laneToReadFrom);
                if (cValue != RTAO::InvalidAOValue && depth != 0 && cDepth != 0)
                {
#if RTAO_MARK_CACHED_VALUES_NEGATIVE
                    cValue = abs(cValue);
#else
                    cValue = abs(cValue);
#endif
                    float w = FilterKernel::Kernel1D[KernelCellIndexStart + c];

                    float depthThreshold = 0.1;
                    float w_d = abs(depth - cDepth) <= depthThreshold * depth;
                    w *= w_d;

                    weightedValueSum += w * cValue;
                    weightSum += w;
                }
            }

            // Combine the sub-results.
            uint laneToReadFrom = min(WaveGetLaneCount() - 1, Row_BaseWaveLaneIndex + GTid16x4.x + GroupDim.x);
            weightedValueSum += WaveReadLaneAt(weightedValueSum, laneToReadFrom);
            weightSum += WaveReadLaneAt(weightSum, laneToReadFrom);

            // Store only the valid results, i.e. first GroupDim columns.
            if (GTid16x4.x < GroupDim.x)
            {
                // ToDo offset row start by rowIndex to avoid bank conflicts on read
                PackedRowResultCache[GTid16x4.y][GTid16x4.x] = Float2ToHalf(float2(weightedValueSum, weightSum));
            }
        }
    }
}

void FilterVertically(uint2 DTid, in uint2 GTid)
{
    float2 valueDepth = HalfToFloat2(PackedValuesDepthsCache[GTid.y + FilterKernel::Radius][GTid.x]);
    float inValue = valueDepth.x;
    float depth = valueDepth.y;
    
    float filteredValue = inValue;

    if ((inValue == RTAO::InvalidAOValue || inValue < 0 ) && depth != 0)
    {
        float weightedValueSum = 0;
        float weightSum = 0;

        // For all rows in the kernel.
        // ToDo Unroll
        for (uint r = 0; r < FilterKernel::Width; r++)
        {
            uint rowID = GTid.y + r;

            float2 rUnpackedValueDepth = HalfToFloat2(PackedValuesDepthsCache[rowID][GTid.x]);
            float rDepth = rUnpackedValueDepth.y;

            if (depth != 0 && rDepth != 0)
            {
                float2 rUnpackedRowResult = HalfToFloat2(PackedRowResultCache[rowID][GTid.x]);
                float rWeightedValueSum = rUnpackedRowResult.x;
                float rWeightSum = rUnpackedRowResult.y;


                float w = FilterKernel::Kernel1D[r];
                float depthThreshold = 0.1;
                float w_d = abs(depth - rDepth) <= depthThreshold * depth;
                w *= w_d;

                weightedValueSum += w * rWeightedValueSum;
                weightSum += w * rWeightSum;
            }
        }
        // Negate updated values from first to so that the second pass knows these values are to be updated again.
        if (cb.step == 1)
        {
            filteredValue = weightSum > 1e-9 ? -weightedValueSum / weightSum : RTAO::InvalidAOValue;
        }
        else
        {
            filteredValue = weightSum > 1e-9 ? weightedValueSum / weightSum : RTAO::InvalidAOValue;
        }
    }

    g_outValues[DTid] = filteredValue;
}


[numthreads(DefaultComputeShaderParams::ThreadGroup::Width, DefaultComputeShaderParams::ThreadGroup::Height, 1)]
void main(uint2 Gid : SV_GroupID, uint2 GTid : SV_GroupThreadID, uint GI : SV_GroupIndex)
{
    uint2 sDTid = GetPixelIndex(Gid, GTid);

    FilterHorizontally(Gid, GI);
    GroupMemoryBarrierWithGroupSync();

    FilterVertically(sDTid, GTid);
}
