/* SPDX-FileCopyrightText: 2023 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup bke
 */

#pragma once

struct Object;

void BKE_editlattice_free(struct Object *ob);
void BKE_editlattice_make(struct Object *obedit);
void BKE_editlattice_load(struct Object *obedit);
