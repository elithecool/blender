/* SPDX-FileCopyrightText: 2016-2023 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "infos/overlay_edit_mode_info.hh"

VERTEX_SHADER_CREATE_INFO(overlay_edit_particle_strand)

#include "draw_model_lib.glsl"
#include "draw_view_clipping_lib.glsl"
#include "draw_view_lib.glsl"

#define no_active_weight 666.0f

float3 weight_to_rgb(float t)
{
  if (t == no_active_weight) {
    /* No weight. */
    return colorWire.rgb;
  }
  if (t > 1.0f || t < 0.0f) {
    /* Error color */
    return float3(1.0f, 0.0f, 1.0f);
  }
  else {
    return texture(weight_tx, t).rgb;
  }
}

void main()
{
  float3 world_pos = drw_point_object_to_world(pos);
  gl_Position = drw_point_world_to_homogenous(world_pos);

  if (use_weight) {
    final_color = float4(weight_to_rgb(selection), 1.0f);
  }
  else {
    float4 use_color = use_grease_pencil ? colorGpencilVertexSelect : colorVertexSelect;
    final_color = mix(colorWireEdit, use_color, selection);
  }

  view_clipping_distances(world_pos);
}
