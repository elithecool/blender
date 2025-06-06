/* SPDX-FileCopyrightText: 2022-2023 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

#include "draw_object_infos_info.hh"

SHADER_LIBRARY_CREATE_INFO(draw_gpencil)

#include "draw_model_lib.glsl"
#include "draw_object_infos_lib.glsl"
#include "draw_view_lib.glsl"
#include "gpu_shader_math_matrix_lib.glsl"
#include "gpu_shader_utildefines_lib.glsl"

#ifndef DRW_GPENCIL_INFO
#  error Missing additional info draw_gpencil
#endif

#ifdef GPU_FRAGMENT_SHADER
float gpencil_stroke_round_cap_mask(
    float2 p1, float2 p2, float2 aspect, float thickness, float hardfac)
{
  /* We create our own uv space to avoid issues with triangulation and linear
   * interpolation artifacts. */
  float2 line = p2.xy - p1.xy;
  float2 pos = gl_FragCoord.xy - p1.xy;
  float line_len = length(line);
  float half_line_len = line_len * 0.5f;
  /* Normalize */
  line = (line_len > 0.0f) ? (line / line_len) : float2(1.0f, 0.0f);
  /* Create a uv space that englobe the whole segment into a capsule. */
  float2 uv_end;
  uv_end.x = max(abs(dot(line, pos) - half_line_len) - half_line_len, 0.0f);
  uv_end.y = dot(float2(-line.y, line.x), pos);
  /* Divide by stroke radius. */
  uv_end /= thickness;
  uv_end *= aspect;

  float dist = clamp(1.0f - length(uv_end) * 2.0f, 0.0f, 1.0f);
  if (hardfac > 0.999f) {
    return step(1e-8f, dist);
  }
  else {
    /* Modulate the falloff profile */
    float hardness = 1.0f - hardfac;
    dist = pow(dist, mix(0.01f, 10.0f, hardness));
    return smoothstep(0.0f, 1.0f, dist);
  }
}
#endif

float2 gpencil_decode_aspect(int packed_data)
{
  float asp = float(uint(packed_data) & 0x1FFu) * (1.0f / 255.0f);
  return (asp > 1.0f) ? float2(1.0f, (asp - 1.0f)) : float2(asp, 1.0f);
}

float gpencil_decode_uvrot(int packed_data)
{
  uint udata = uint(packed_data);
  float uvrot = 1e-8f + float((udata & 0x1FE00u) >> 9u) * (1.0f / 255.0f);
  return ((udata & 0x20000u) != 0u) ? -uvrot : uvrot;
}

float gpencil_decode_hardness(int packed_data)
{
  return float((uint(packed_data) & 0x3FC0000u) >> 18u) * (1.0f / 255.0f);
}

float2 gpencil_project_to_screenspace(float4 v, float4 viewport_res)
{
  return ((v.xy / v.w) * 0.5f + 0.5f) * viewport_res.xy;
}

float gpencil_stroke_thickness_modulate(float thickness, float4 ndc_pos, float4 viewport_res)
{
  /* Modify stroke thickness by object scale. */
  thickness = length(to_float3x3(drw_modelmat()) * float3(thickness * M_SQRT1_3));

  /* For compatibility, thickness has to be clamped after being multiplied by this factor.
   * This clamping was introduced to reduce aliasing issue by instead fading the lines alpha at
   * smaller radii. This can be removed in major release if compatibility is not a concern. */
  const float legacy_radius_conversion_factor = 2000.0f;
  thickness *= legacy_radius_conversion_factor;
  thickness = max(1.0f, thickness);
  thickness /= legacy_radius_conversion_factor;

  /* World space point size. */
  thickness *= drw_view().winmat[1][1] * viewport_res.y;

  return thickness;
}

float gpencil_clamp_small_stroke_thickness(float thickness, float4 ndc_pos)
{
  /* To avoid aliasing artifacts, we clamp the line thickness and
   * reduce its opacity in the fragment shader. */
  float min_thickness = ndc_pos.w * 1.3f;
  thickness = max(min_thickness, thickness);

  return thickness;
}

#ifdef GPU_VERTEX_SHADER

int gpencil_stroke_point_id()
{
  return (gl_VertexID & ~GP_IS_STROKE_VERTEX_BIT) >> GP_VERTEX_ID_SHIFT;
}

bool gpencil_is_stroke_vertex()
{
  return flag_test(gl_VertexID, GP_IS_STROKE_VERTEX_BIT);
}

/**
 * Returns value of gl_Position.
 *
 * To declare in vertex shader.
 * in ivec4 ma, ma1, ma2, ma3;
 * in float4 pos, pos1, pos2, pos3, uv1, uv2, col1, col2, fcol1;
 *
 * All of these attributes are quad loaded the same way
 * as GL_LINES_ADJACENCY would feed a geometry shader:
 * - ma reference the previous adjacency point.
 * - ma1 reference the current line first point.
 * - ma2 reference the current line second point.
 * - ma3 reference the next adjacency point.
 * Note that we are rendering quad instances and not using any index buffer
 *(except for fills).
 *
 * Material : x is material index, y is stroke_id, z is point_id,
 *            w is aspect & rotation & hardness packed.
 * Position : contains thickness in 4th component.
 * UV : xy is UV for fills, z is U of stroke, w is strength.
 *
 *
 * WARNING: Max attribute count is actually 14 because OSX OpenGL implementation
 * considers gl_VertexID and gl_InstanceID as vertex attribute. (see #74536)
 */
float4 gpencil_vertex(float4 viewport_res,
                      gpMaterialFlag material_flags,
                      float2 alignment_rot,
                      /* World Position. */
                      out float3 out_P,
                      /* World Normal. */
                      out float3 out_N,
                      /* Vertex Color. */
                      out float4 out_color,
                      /* Stroke Strength. */
                      out float out_strength,
                      /* UV coordinates. */
                      out float2 out_uv,
                      /* Screen-Space segment endpoints. */
                      out float4 out_sspos,
                      /* Stroke aspect ratio. */
                      out float2 out_aspect,
                      /* Stroke thickness (x: clamped, y: unclamped). */
                      out float2 out_thickness,
                      /* Stroke hardness. */
                      out float out_hardness)
{
  int stroke_point_id = (gl_VertexID & ~GP_IS_STROKE_VERTEX_BIT) >> GP_VERTEX_ID_SHIFT;

  /* Attribute Loading. */
  float4 pos = texelFetch(gp_pos_tx, (stroke_point_id - 1) * 3 + 0);
  float4 pos1 = texelFetch(gp_pos_tx, (stroke_point_id + 0) * 3 + 0);
  float4 pos2 = texelFetch(gp_pos_tx, (stroke_point_id + 1) * 3 + 0);
  float4 pos3 = texelFetch(gp_pos_tx, (stroke_point_id + 2) * 3 + 0);
  int4 ma = floatBitsToInt(texelFetch(gp_pos_tx, (stroke_point_id - 1) * 3 + 1));
  int4 ma1 = floatBitsToInt(texelFetch(gp_pos_tx, (stroke_point_id + 0) * 3 + 1));
  int4 ma2 = floatBitsToInt(texelFetch(gp_pos_tx, (stroke_point_id + 1) * 3 + 1));
  int4 ma3 = floatBitsToInt(texelFetch(gp_pos_tx, (stroke_point_id + 2) * 3 + 1));
  float4 uv1 = texelFetch(gp_pos_tx, (stroke_point_id + 0) * 3 + 2);
  float4 uv2 = texelFetch(gp_pos_tx, (stroke_point_id + 1) * 3 + 2);

  float4 col1 = texelFetch(gp_col_tx, (stroke_point_id + 0) * 2 + 0);
  float4 col2 = texelFetch(gp_col_tx, (stroke_point_id + 1) * 2 + 0);
  float4 fcol1 = texelFetch(gp_col_tx, (stroke_point_id + 0) * 2 + 1);

#  define thickness1 pos1.w
#  define thickness2 pos2.w
#  define strength1 uv1.w
#  define strength2 uv2.w
/* Packed! need to be decoded. */
#  define hardness1 ma1.w
#  define hardness2 ma2.w
#  define uvrot1 ma1.w
#  define aspect1 ma1.w

  float4 out_ndc;

  if (gpencil_is_stroke_vertex()) {
    bool is_dot = flag_test(material_flags, GP_STROKE_ALIGNMENT);
    bool is_squares = !flag_test(material_flags, GP_STROKE_DOTS);

    /* Special Case. Stroke with single vert are rendered as dots. Do not discard them. */
    if (!is_dot && ma.x == -1 && ma2.x == -1) {
      is_dot = true;
      is_squares = false;
    }

    /* Endpoints, we discard the vertices. */
    if (!is_dot && ma2.x == -1) {
      /* We set the vertex at the camera origin to generate 0 fragments. */
      out_ndc = float4(0.0f, 0.0f, -3e36f, 0.0f);
      return out_ndc;
    }

    /* Avoid using a vertex attribute for quad positioning. */
    float x = float(gl_VertexID & 1) * 2.0f - 1.0f; /* [-1..1] */
    float y = float(gl_VertexID & 2) - 1.0f;        /* [-1..1] */

    bool use_curr = is_dot || (x == -1.0f);

    float3 wpos_adj = transform_point(drw_modelmat(), (use_curr) ? pos.xyz : pos3.xyz);
    float3 wpos1 = transform_point(drw_modelmat(), pos1.xyz);
    float3 wpos2 = transform_point(drw_modelmat(), pos2.xyz);

    float3 T;
    if (is_dot) {
      /* Shade as facing billboards. */
      T = drw_view().viewinv[0].xyz;
    }
    else if (use_curr && ma.x != -1) {
      T = wpos1 - wpos_adj;
    }
    else {
      T = wpos2 - wpos1;
    }
    T = safe_normalize(T);

    float3 B = cross(T, drw_view().viewinv[2].xyz);
    out_N = normalize(cross(B, T));

    float4 ndc_adj = drw_point_world_to_homogenous(wpos_adj);
    float4 ndc1 = drw_point_world_to_homogenous(wpos1);
    float4 ndc2 = drw_point_world_to_homogenous(wpos2);

    out_ndc = (use_curr) ? ndc1 : ndc2;
    out_P = (use_curr) ? wpos1 : wpos2;
    out_strength = abs((use_curr) ? strength1 : strength2);

    float2 ss_adj = gpencil_project_to_screenspace(ndc_adj, viewport_res);
    float2 ss1 = gpencil_project_to_screenspace(ndc1, viewport_res);
    float2 ss2 = gpencil_project_to_screenspace(ndc2, viewport_res);
    /* Screen-space Lines tangents. */
    float line_len;
    float2 line = safe_normalize_and_get_length(ss2 - ss1, line_len);
    float2 line_adj = safe_normalize((use_curr) ? (ss1 - ss_adj) : (ss_adj - ss2));

    float thickness = abs((use_curr) ? thickness1 : thickness2);
    thickness = gpencil_stroke_thickness_modulate(thickness, out_ndc, viewport_res);
    float clamped_thickness = gpencil_clamp_small_stroke_thickness(thickness, out_ndc);

    out_uv = float2(x, y) * 0.5f + 0.5f;
    out_hardness = gpencil_decode_hardness(use_curr ? hardness1 : hardness2);

    if (is_dot) {
      uint alignment_mode = material_flags & GP_STROKE_ALIGNMENT;

      /* For one point strokes use object alignment. */
      if (alignment_mode == GP_STROKE_ALIGNMENT_STROKE && ma.x == -1 && ma2.x == -1) {
        alignment_mode = GP_STROKE_ALIGNMENT_OBJECT;
      }

      float2 x_axis;
      if (alignment_mode == GP_STROKE_ALIGNMENT_STROKE) {
        x_axis = (ma2.x == -1) ? line_adj : line;
      }
      else if (alignment_mode == GP_STROKE_ALIGNMENT_FIXED) {
        /* Default for no-material drawing. */
        x_axis = float2(1.0f, 0.0f);
      }
      else { /* GP_STROKE_ALIGNMENT_OBJECT */
        float4 ndc_x = drw_point_world_to_homogenous(wpos1 + drw_modelmat()[0].xyz);
        float2 ss_x = gpencil_project_to_screenspace(ndc_x, viewport_res);
        x_axis = safe_normalize(ss_x - ss1);
      }

      /* Rotation: Encoded as Cos + Sin sign. */
      float uv_rot = gpencil_decode_uvrot(uvrot1);
      float rot_sin = sqrt(max(0.0f, 1.0f - uv_rot * uv_rot)) * sign(uv_rot);
      float rot_cos = abs(uv_rot);
      /* TODO(@fclem): Optimize these 2 matrix multiply into one by only having one rotation angle
       * and using a cosine approximation. */
      x_axis = float2x2(rot_cos, -rot_sin, rot_sin, rot_cos) * x_axis;
      x_axis = float2x2(alignment_rot.x, -alignment_rot.y, alignment_rot.y, alignment_rot.x) *
               x_axis;
      /* Rotate 90 degrees counter-clockwise. */
      float2 y_axis = float2(-x_axis.y, x_axis.x);

      out_aspect = gpencil_decode_aspect(aspect1);

      x *= out_aspect.x;
      y *= out_aspect.y;

      /* Invert for vertex shader. */
      out_aspect = 1.0f / out_aspect;

      out_ndc.xy += (x * x_axis + y * y_axis) * viewport_res.zw * clamped_thickness;

      out_sspos.xy = ss1;
      out_sspos.zw = ss1 + x_axis * 0.5f;
      out_thickness.x = (is_squares) ? 1e18f : (clamped_thickness / out_ndc.w);
      out_thickness.y = (is_squares) ? 1e18f : (thickness / out_ndc.w);
    }
    else {
      bool is_stroke_start = (ma.x == -1 && x == -1);
      bool is_stroke_end = (ma3.x == -1 && x == 1);

      /* Mitter tangent vector. */
      float2 miter_tan = safe_normalize(line_adj + line);
      float miter_dot = dot(miter_tan, line_adj);
      /* Break corners after a certain angle to avoid really thick corners. */
      const float miter_limit = 0.5f; /* cos(60 degrees) */
      bool miter_break = (miter_dot < miter_limit);
      miter_tan = (miter_break || is_stroke_start || is_stroke_end) ? line :
                                                                      (miter_tan / miter_dot);
      /* Rotate 90 degrees counter-clockwise. */
      float2 miter = float2(-miter_tan.y, miter_tan.x);

      out_sspos.xy = ss1;
      out_sspos.zw = ss2;
      out_thickness.x = clamped_thickness / out_ndc.w;
      out_thickness.y = thickness / out_ndc.w;
      out_aspect = float2(1.0f);

      float2 screen_ofs = miter * y;

      /* Reminder: we packed the cap flag into the sign of strength and thickness sign. */
      if ((is_stroke_start && strength1 > 0.0f) || (is_stroke_end && thickness1 > 0.0f) ||
          (miter_break && !is_stroke_start && !is_stroke_end))
      {
        screen_ofs += line * x;
      }

      out_ndc.xy += screen_ofs * viewport_res.zw * clamped_thickness;

      out_uv.x = (use_curr) ? uv1.z : uv2.z;
    }

    out_color = (use_curr) ? col1 : col2;
  }
  else {
    out_P = transform_point(drw_modelmat(), pos1.xyz);
    out_ndc = drw_point_world_to_homogenous(out_P);
    out_uv = uv1.xy;
    out_thickness.x = 1e18f;
    out_thickness.y = 1e20f;
    out_hardness = 1.0f;
    out_aspect = float2(1.0f);
    out_sspos = float4(0.0f);

    /* Flat normal following camera and object bounds. */
    float3 V = drw_world_incident_vector(drw_modelmat()[3].xyz);
    float3 N = drw_normal_world_to_object(V);
    N *= drw_object_infos().orco_mul;
    N = drw_normal_world_to_object(N);
    out_N = safe_normalize(N);

    /* Decode fill opacity. */
    out_color = float4(fcol1.rgb, floor(fcol1.a / 10.0f) / 10000.0f);

    /* We still offset the fills a little to avoid overlaps */
    out_ndc.z += 0.000002f;
  }

#  undef thickness1
#  undef thickness2
#  undef strength1
#  undef strength2
#  undef hardness1
#  undef hardness2
#  undef uvrot1
#  undef aspect1

  return out_ndc;
}

float4 gpencil_vertex(float4 viewport_res,
                      out float3 out_P,
                      out float3 out_N,
                      out float4 out_color,
                      out float out_strength,
                      out float2 out_uv,
                      out float4 out_sspos,
                      out float2 out_aspect,
                      out float2 out_thickness,
                      out float out_hardness)
{
  return gpencil_vertex(viewport_res,
                        gpMaterialFlag(0u),
                        float2(1.0f, 0.0f),
                        out_P,
                        out_N,
                        out_color,
                        out_strength,
                        out_uv,
                        out_sspos,
                        out_aspect,
                        out_thickness,
                        out_hardness);
}

#endif
