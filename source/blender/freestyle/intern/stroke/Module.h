/* SPDX-FileCopyrightText: 2023 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

/** \file
 * \ingroup freestyle
 * \brief Set the type of the module
 */

#include "Canvas.h"
#include "StyleModule.h"

#include "MEM_guardedalloc.h"

namespace Freestyle {

class Module {
 public:
  static void setAlwaysRefresh(bool b = true)
  {
    getCurrentStyleModule()->setAlwaysRefresh(b);
  }

  static void setCausal(bool b = true)
  {
    getCurrentStyleModule()->setCausal(b);
  }

  static void setDrawable(bool b = true)
  {
    getCurrentStyleModule()->setDrawable(b);
  }

  static bool getAlwaysRefresh()
  {
    return getCurrentStyleModule()->getAlwaysRefresh();
  }

  static bool getCausal()
  {
    return getCurrentStyleModule()->getCausal();
  }

  static bool getDrawable()
  {
    return getCurrentStyleModule()->getDrawable();
  }

 private:
  static StyleModule *getCurrentStyleModule()
  {
    Canvas *canvas = Canvas::getInstance();
    return canvas->getCurrentStyleModule();
  }

  MEM_CXX_CLASS_ALLOC_FUNCS("Freestyle:Module")
};

} /* namespace Freestyle */
