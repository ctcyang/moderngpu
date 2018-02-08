/******************************************************************************
 * Copyright (c) 2013, NVIDIA CORPORATION.  All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/******************************************************************************
 *
 * Code and text by Sean Baxter, NVIDIA Research
 * See http://nvlabs.github.io/moderngpu for repository and documentation.
 *
 ******************************************************************************/

#pragma once

#include "../kernels/csrtools.cuh"

//#include "../constants.h"

namespace mgpu {

////////////////////////////////////////////////////////////////////////////////
// SegReducePreprocess
	
struct SegReducePreprocessData {
	int count, numSegments, numSegments2;
	int numBlocks;
	MGPU_MEM(int) limitsDevice;
	MGPU_MEM(int) threadCodesDevice;

	// If csr2Device is set, use BulkInsert to finalize results into 
	// dest_global.
	MGPU_MEM(int) csr2Device;
};

// Generic function for prep
template<typename Tuning, typename CsrIt>
MGPU_HOST void SegReducePreprocess(int count, CsrIt csr_global, int numSegments,
	bool supportEmpty, std::auto_ptr<SegReducePreprocessData>* ppData, 
	CudaContext& context) {

	std::auto_ptr<SegReducePreprocessData> data(new SegReducePreprocessData);

	int2 launch = Tuning::GetLaunchParams(context);
	int NV = launch.x * launch.y;

	int numBlocks = MGPU_DIV_UP(count, NV);
	data->count = count;
	data->numSegments = data->numSegments2 = numSegments;
	data->numBlocks = numBlocks;

	// Filter out empty rows and build a replacement structure.
	if(supportEmpty) {
		MGPU_MEM(int) csr2Device = context.Malloc<int>(numSegments + 1);
		CsrStripEmpties<false>(count, csr_global, (const int*)0, numSegments,
			csr2Device->get(), (int*)0, (int*)&data->numSegments2, context); 
		if(data->numSegments2 < numSegments) {
			csr_global = csr2Device->get();
			numSegments = data->numSegments2;
			data->csr2Device = csr2Device;
		}
	}

	data->limitsDevice = PartitionCsrSegReduce(count, NV, csr_global,
		numSegments, (const int*)0, numBlocks + 1, context);
	data->threadCodesDevice = BuildCsrPlus<Tuning>(count, csr_global, 
		data->limitsDevice->get(), numBlocks, context);

	*ppData = data;
}

////////////////////////////////////////////////////////////////////////////////
// SegReduceSpine
// Compute the carry-in in-place. Return the carry-out for the entire tile.
// A final spine-reducer scans the tile carry-outs and adds into individual
// results.

template<int NT, typename T, typename DestIt, typename Op>
__global__ void KernelSegReduceSpine1(const int* limits_global, 
  int count, DestIt dest_global, const T* carryIn_global, T identity, Op op,
	T* carryOut_global) {

	typedef CTASegScan<NT, Op> SegScan;
	union Shared {
		typename SegScan::Storage segScanStorage;
	};
	__shared__ Shared shared;

	int tid = threadIdx.x;
	int block = blockIdx.x;
	int gid = NT * block + tid;

	// Load the current carry-in and the current and next row indices.
	int row = (gid < count) ? 
		(0x7fffffff & limits_global[gid]) :
		INT_MAX;
	int row2 = (gid + 1 < count) ? 
		(0x7fffffff & limits_global[gid + 1]) :
		INT_MAX;

  // Depending on register usage, could consider changing MGPU_TB 
  // here to MGPU_BC
	/*T carryIn2[MGPU_TB];
	T dest[    MGPU_TB];

	// Run a segmented scan of the carry-in values.
	bool endFlag = row != row2;

	T carryOut[MGPU_TB];
	T x[       MGPU_TB];

  for( int slab=0; slab<MGPU_BC/MGPU_TB; slab++ )
  {
    #pragma unroll
    for( int j=0; j<MGPU_TB; j++ )
    {	
      carryIn2[j] = (gid < count) ? 
        carryIn_global[block+j*gridDim.x+slab*MGPU_TB*gridDim.x] : identity;
      dest[j]     = (gid < count) ? 
        dest_global[row*MGPU_BC+j+slab*MGPU_TB] : identity;
      x[j] = SegScan::SegScan(tid, carryIn2[j], endFlag, 
        shared.segScanStorage, &carryOut[j], identity, op);
    }

    // Store the reduction at the end of a segment to dest_global.
    if(endFlag)
      #pragma unroll
      for( int j=0; j<MGPU_TB; j++ )
        dest_global[row*MGPU_BC+j+slab*MGPU_TB] = op(x[j], dest[j]);
    
    // Store the CTA carry-out.
    if(!tid)
      #pragma unroll
      for( int j=0; j<MGPU_TB; j++ )
        carryOut_global[block+j*gridDim.x+slab*MGPU_TB*gridDim.x] = carryOut[j];
  }*/
}

template<int TB, int NT, typename T, typename DestIt, typename Op>
__global__ void KernelSegReduceSpine1Prealloc(const int* limits_global, 
  int count, DestIt dest_global, const T* carryIn_global, T identity, Op op,
	T* carryOut_global) {

	typedef CTASegScan<NT, Op> SegScan;
	union Shared {
		typename SegScan::Storage segScanStorage;
	};
	__shared__ Shared shared;

	int tid = threadIdx.x;
	int block = blockIdx.x;
	int gid = NT * block + tid;

	// Load the current carry-in and the current and next row indices.
	int row = (gid < count) ? 
		(0x7fffffff & limits_global[gid]) :
		INT_MAX;
	int row2 = (gid + 1 < count) ? 
		(0x7fffffff & limits_global[gid + 1]) :
		INT_MAX;

  // Depending on register usage, could consider changing TB 
  // here to MGPU_BC
	T carryIn2[TB];
	T dest[    TB];

	// Run a segmented scan of the carry-in values.
	bool endFlag = row != row2;

	T carryOut[TB];
	T x[       TB];

  for( int slab=0; slab<32/TB; slab++ )
  {
    #pragma unroll
    for( int j=0; j<TB; j++ )
    {	
      carryIn2[j] = (gid < count) ? 
        carryIn_global[block+j*gridDim.x+slab*TB*gridDim.x] : identity;
      dest[j]     = (gid < count) ? 
        dest_global[row*32+j+slab*TB] : identity;
      x[j] = SegScan::SegScan(tid, carryIn2[j], endFlag, 
        shared.segScanStorage, &carryOut[j], identity, op);
    }

    // Store the reduction at the end of a segment to dest_global.
    if(endFlag)
      #pragma unroll
      for( int j=0; j<TB; j++ )
        dest_global[row*32+j+slab*TB] = op(x[j], dest[j]);
    
    // Store the CTA carry-out.
    if(!tid)
      #pragma unroll
      for( int j=0; j<TB; j++ )
        carryOut_global[block+j*gridDim.x+slab*TB*gridDim.x] = carryOut[j];
  }
}

template<int NT, typename T, typename DestIt, typename Op>
__global__ void KernelSegReduceSpine2(const int* limits_global, int numBlocks,
	int count, int nv, DestIt dest_global, const T* carryIn_global, T identity,
	Op op) {

	typedef CTASegScan<NT, Op> SegScan;
	struct Shared {
		typename SegScan::Storage segScanStorage;
		int carryInRow;
		T   carryIn;
	};
	__shared__ Shared shared;

	int tid = threadIdx.x;
	
	for(int i = 0; i < numBlocks; i += NT) {
		int gid = (i + tid) * nv;

		// Load the current carry-in and the current and next row indices.
		int row = (gid < count) ? 
			(0x7fffffff & limits_global[gid]) : INT_MAX;
		int row2 = (gid + nv < count) ? 
			(0x7fffffff & limits_global[gid + nv]) : INT_MAX;
		T carryIn2, dest;
		/*T carryOut[MGPU_TB], x[MGPU_TB];

		// Run a segmented scan of the carry-in values.
		bool endFlag = row != row2;

    for( int slab=0; slab<MGPU_BC/MGPU_TB; slab++ )
    {
      #pragma unroll
      for( int j=0; j<MGPU_TB; j++ )
      {
        carryIn2[j] = (i + tid < numBlocks) ? 
          carryIn_global[i+tid+j*gridDim.x+slab*MGPU_TB*gridDim.x]:identity;
        dest[j] = (gid < count) ? 
          dest_global[row*MGPU_BC+j+slab*MGPU_TB] : identity;
        x[j] = SegScan::SegScan(tid, carryIn2[j], endFlag, 
          shared.segScanStorage,&carryOut[j], identity, op);
      }

      // Add the carry-in to the reductions when we get to the end of a segment.
      if(endFlag) {
        // Add the carry-in from the last loop iteration to the carry-in
        // from this loop iteration.
        #pragma unroll
        for( int j=0; j<MGPU_TB; j++ )
        {
          if(i && row == shared.carryInRow) 
            x[j] = op(shared.carryIn[j], x[j]);
          dest_global[row*MGPU_BC+j+slab*MGPU_TB] = op(x[j], dest[j]);
        }
      }

      // Set the carry-in for the next loop iteration.
      if(i + NT < numBlocks) {
        __syncthreads();
        if(i > 0) {
          // Add in the previous carry-in.
          if(NT - 1 == tid) {
            #pragma unroll
            for( int j=0; j<MGPU_TB; j++ )
            {
              shared.carryIn[j] = (shared.carryInRow == row2) ?
                op(shared.carryIn[j], carryOut[j]) : carryOut[j];
              shared.carryInRow = row2;
            }
          }
        } else {
          if(NT - 1 == tid) {
            #pragma unroll
            for( int j=0; j<MGPU_TB; j++ )
            {
              shared.carryIn[j] = carryOut[j];
              shared.carryInRow = row2;
            }
          }
        }
        __syncthreads();
      }
    }*/
	}
}

template<int TB, int NT, typename T, typename DestIt, typename Op>
__global__ void KernelSegReduceSpine2Prealloc(const int* limits_global, 
  int numBlocks, int count, DestIt dest_global, const T* carryIn_global,
  T identity, Op op) {

	typedef CTASegScan<NT, Op> SegScan;
	struct Shared {
		typename SegScan::Storage segScanStorage;
		int carryInRow;
		T carryIn[TB];
	};
	__shared__ Shared shared;

	int tid = threadIdx.x;
	
	for(int i = 0; i < numBlocks; i += NT) {
		int gid = (i + tid) * NT;

		// Load the current carry-in and the current and next row indices.
		int row = (gid < count) ? 
			(0x7fffffff & limits_global[gid]) : INT_MAX;
		int row2 = (gid + NT < count) ? 
			(0x7fffffff & limits_global[gid + NT]) : INT_MAX;
		T carryIn2[TB], dest[TB];
		T carryOut[TB], x[TB];

		// Run a segmented scan of the carry-in values.
		bool endFlag = row != row2;

    for( int slab=0; slab<32/TB; slab++ )
    {
      #pragma unroll
      for( int j=0; j<TB; j++ )
      {
        carryIn2[j] = (i + tid < numBlocks) ? 
          carryIn_global[i+tid+j*gridDim.x+slab*TB*gridDim.x]:identity;
        dest[j] = (gid < count) ? 
          dest_global[row*32+j+slab*TB] : identity;
        x[j] = SegScan::SegScan(tid, carryIn2[j], endFlag, 
          shared.segScanStorage,&carryOut[j], identity, op);
      }

      // Add the carry-in to the reductions when we get to the end of a segment.
      if(endFlag) {
        // Add the carry-in from the last loop iteration to the carry-in
        // from this loop iteration.
        #pragma unroll
        for( int j=0; j<TB; j++ )
        {
          if(i && row == shared.carryInRow) 
            x[j] = op(shared.carryIn[j], x[j]);
          dest_global[row*32+j+slab*TB] = op(x[j], dest[j]);
        }
      }

      // Set the carry-in for the next loop iteration.
      if(i + NT < numBlocks) {
        __syncthreads();
        if(i > 0) {
          // Add in the previous carry-in.
          if(NT - 1 == tid) {
            #pragma unroll
            for( int j=0; j<TB; j++ )
            {
              shared.carryIn[j] = (shared.carryInRow == row2) ?
                op(shared.carryIn[j], carryOut[j]) : carryOut[j];
              shared.carryInRow = row2;
            }
          }
        } else {
          if(NT - 1 == tid) {
            #pragma unroll
            for( int j=0; j<TB; j++ )
            {
              shared.carryIn[j] = carryOut[j];
              shared.carryInRow = row2;
            }
          }
        }
        __syncthreads();
      }
    }
	}
}

template<typename T, typename Op, typename DestIt>
MGPU_HOST void SegReduceSpine(const int* limits_global, int count, 
	DestIt dest_global, const T* carryIn_global, T identity, Op op, 
	CudaContext& context) {

	const int NT = 128;
	int numBlocks = MGPU_DIV_UP(count, NT);

	// Fix-up the segment outputs between the original tiles.
	MGPU_MEM(T) carryOutDevice = context.Malloc<T>(numBlocks);
	KernelSegReduceSpine1<NT><<<numBlocks, NT, 0, context.Stream()>>>(
		limits_global, count, dest_global, carryIn_global, identity, op,
		carryOutDevice->get());
	MGPU_SYNC_CHECK("KernelSegReduceSpine1");

	// Loop over the segments that span the tiles of 
	// KernelSegReduceSpine1 and fix those.
	if(numBlocks > 1) {
		KernelSegReduceSpine2<NT><<<1, NT, 0, context.Stream()>>>(
			limits_global, numBlocks, count, NT, dest_global,
			carryOutDevice->get(), identity, op);
		MGPU_SYNC_CHECK("KernelSegReduceSpine2");
	}
}

// For SpMM
template<int TB, int NT, typename T, typename Op, typename DestIt>
MGPU_HOST void SegReduceSpinePrealloc(const int* limits_global, int count, 
	DestIt dest_global, const T* carryIn_global, T* carryOut_global, T identity, 
  Op op, CudaContext& context) {

	int numBlocks = MGPU_DIV_UP(count, NT);

	// Fix-up the segment outputs between the original tiles.
	//MGPU_MEM(T) carryOutDevice = context.Malloc<T>(numBlocks);
	KernelSegReduceSpine1Prealloc<TB,NT><<<numBlocks, NT, 0, context.Stream()>>>(
		limits_global, count, dest_global, carryIn_global, identity, op,
		carryOut_global);
	MGPU_SYNC_CHECK("KernelSegReduceSpine1");

	// Loop over the segments that span the tiles of 
	// KernelSegReduceSpine1 and fix those.
	if(numBlocks > 1) {
		KernelSegReduceSpine2Prealloc<TB,NT><<<1, NT, 0, context.Stream()>>>(
			limits_global, numBlocks, count, dest_global, carryOut_global, identity, 
      op);
		MGPU_SYNC_CHECK("KernelSegReduceSpine2");
	}
}
////////////////////////////////////////////////////////////////////////////////
// Common LaunchBox structure for segmented reductions.

template<int NT_, int VT_, int OCC_, bool HalfCapacity_, bool LdgTranspose_>
struct SegReduceTuning {
	enum { 
		NT = NT_,
		VT = VT_, 
		OCC = OCC_,
		HalfCapacity = HalfCapacity_,
		LdgTranspose = LdgTranspose_
	};
};

} // namespace mgpu
