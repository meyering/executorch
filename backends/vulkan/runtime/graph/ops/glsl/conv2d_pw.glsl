/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#version 450 core

#define PRECISION ${PRECISION}

#define VEC4_T ${texel_type(DTYPE)}

#define TILE_SIZE ${TILE_SIZE}

#define op(X, A, B) ${OPERATOR}

#include "indexing_utils.h"

layout(std430) buffer;

layout(set = 0, binding = 0, ${IMAGE_FORMAT[DTYPE]}) uniform PRECISION restrict writeonly ${IMAGE_T[NDIM][DTYPE]} image_out;
layout(set = 0, binding = 1) uniform PRECISION sampler3D image_in;
layout(set = 0, binding = 2) uniform PRECISION sampler2D kernel_in;
layout(set = 0, binding = 3) uniform PRECISION sampler2D bias_in;

layout(set = 0, binding = 4) uniform PRECISION restrict OutLimits {
  ivec3 out_limits;
};

layout(set = 0, binding = 5) uniform PRECISION restrict InSizes {
  ivec4 data;
};

layout(set = 0, binding = 6) uniform PRECISION restrict Params {
  ivec2 kernel_size;
  ivec2 stride;
  ivec2 padding;
  ivec2 dilation;
};

// If fields are separated, SwiftShader cannot identify in_group_size.
layout(set = 0, binding = 7) uniform PRECISION restrict ExtraParams {
  ivec2 overlay_region;
  int in_group_size;
};

layout(set = 0, binding = 8) uniform PRECISION restrict OutputParams {
  float out_min;
  float out_max;
};

layout(local_size_x_id = 0, local_size_y_id = 1, local_size_z_id = 2) in;

/*
 * Computes a 2D pointwise convolution of an NxN output tile. Calculating an
 * output tile for pointwise convolution is more efficient because the kernel
 * size is only 1x1, making it easier to re-use loaded texels from kernel_in.
 */
void main() {
  const ivec3 gpos = ivec3(gl_GlobalInvocationID);

  // Output position for TILE_SIZE = 2
  // +--------+--------+
  // | pos[0] | pos[1] |
  // +--------+--------+
  // | pos[2] | pos[3] |
  // +--------+--------+
  ivec3 pos[TILE_SIZE * TILE_SIZE];
  for (int y = 0, i = 0; y < TILE_SIZE; ++y) {
    for (int x = 0; x < TILE_SIZE; ++x) {
      pos[i] = ivec3(
          gpos.x * TILE_SIZE + x, gpos.y * TILE_SIZE + y, gpos.z);
      i++;
    }
  }

  // If the top left position is out of bounds, then this invocation will have
  // no work to do.
  if (any(greaterThanEqual(pos[0], out_limits))) {
    return;
  }

  // Compute the index of the input texture that needs to be loaded for each
  // output position. Note that negative indices can be produced indicating that
  // the top-left element is in a region added by padding.
  ivec2 ipos[TILE_SIZE * TILE_SIZE];
  for (int i = 0; i < TILE_SIZE * TILE_SIZE; ++i) {
    ipos[i] = pos[i].xy * stride - padding;
  }

  vec4 sum[TILE_SIZE * TILE_SIZE];
  sum[0] = texelFetch(bias_in, ivec2(gpos.z, 0), 0);
  for (int i = 1; i < TILE_SIZE * TILE_SIZE; ++i) {
    sum[i] = sum[0];
  }

  // Since the kernel is 1x1, we only have to loop over the depth dimension.
  for (int z = 0, z4 = 0; z < in_group_size; z += 4, ++z4) {
    // During prepacking, the weight tensor has been permuted so that the
    // channel (IC) dim is along the x-axis, and the batch (OC) dim is along
    // the z-axis.
    vec4 in_tex[TILE_SIZE * TILE_SIZE];
    const vec4 ktex_0 = texelFetch(kernel_in, ivec2(z + 0, gpos.z), 0);
    const vec4 ktex_1 = texelFetch(kernel_in, ivec2(z + 1, gpos.z), 0);
    const vec4 ktex_2 = texelFetch(kernel_in, ivec2(z + 2, gpos.z), 0);
    const vec4 ktex_3 = texelFetch(kernel_in, ivec2(z + 3, gpos.z), 0);

    for (int i = 0; i < TILE_SIZE * TILE_SIZE; ++i) {
      in_tex[i] = texelFetch(image_in, ivec3(ipos[i], z4), 0);
    }

    for (int i = 0; i < TILE_SIZE * TILE_SIZE; ++i) {
      // For 2x2 tile size algorithm works as follows.
      // To explain the calculations below, the contents of one in_tex and the
      // group of 4 texels loaded from kernel_in are shown:
      //
      //   in_tex                 kernel_in
      //    -x->                   ---x--->
      //   +---+              +----+----+----+----+
      // ^ | w |           ^  | D0 | D1 | D2 | D3 |
      // | +---+           |  +----+----+----+----+
      // | | z |           |  | C0 | C1 | C2 | C3 |
      // z +---+           z  +----+----+----+----+
      // | | y |           |  | B0 | B2 | B2 | B3 |
      // | +---+           |  +----+----+----+----+
      //   | x |              | A0 | A1 | A2 | A3 |
      //   +---+              +----+----+----+----+
      //
      // In the kernel_in graphic, cells sharing the same letter are from
      // the same batch/output channel index, and the number denotes a unique
      // channel index. To calculate the output texel, the following
      // calculation is performed:
      //
      //  +---+ +----+   +---+ +----+   +---+ +----+   +---+ +----+
      //  | x | | D0 |   | y | | D1 |   | z | | D2 |   | w | | D3 |
      //  +---+ +----+   +---+ +----+   +---+ +----+   +---+ +----+
      //  | x | | C0 |   | y | | C1 |   | z | | C2 |   | w | | C3 |
      //  +---+X+----+ + +---+X+----+ + +---+X+----+ + +---+X+----+
      //  | x | | B0 |   | y | | B1 |   | z | | B2 |   | w | | B3 |
      //  +---+ +----+   +---+ +----+   +---+ +----+   +---+ +----+
      //  | x | | A0 |   | y | | A1 |   | z | | A2 |   | w | | A3 |
      //  +---+ +----+   +---+ +----+   +---+ +----+   +---+ +----+
      //
      //  which is what is expressed in the following calculations. This is done
      //  for each output position.
      sum[i] = fma(in_tex[i].xxxx, ktex_0, sum[i]);
      sum[i] = fma(in_tex[i].yyyy, ktex_1, sum[i]);
      sum[i] = fma(in_tex[i].zzzz, ktex_2, sum[i]);
      sum[i] = fma(in_tex[i].wwww, ktex_3, sum[i]);
    }
  }

  for (int i = 0; i < TILE_SIZE * TILE_SIZE; ++i) {
    if (all(lessThan(pos[i], out_limits))) {
      imageStore(image_out, pos[i], op(sum[i], out_min, out_max));
    }
  }
}
