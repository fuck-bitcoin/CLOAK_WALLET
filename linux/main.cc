#include "my_application.h"
#include <stdlib.h>

int main(int argc, char** argv) {
  // REMOVED: LIBGL_ALWAYS_SOFTWARE=1 caused Flutter rendering regression
  // (flutter/flutter#169508). Intel UHD 620 has good hardware GL support.
  // The software rendering (llvmpipe) path has known black-screen bugs
  // on Flutter 3.23+ with XWayland.

  // Force X11/XWayland backend so that window_manager's
  // gtk_window_set_keep_above() actually works for always-on-top.
  // On pure Wayland, GNOME silently ignores the keep-above hint.
  // Note: my_application.cc detects XWayland and uses SSD (server-side
  // decorations) instead of GtkHeaderBar CSD to avoid geometry mismatch.
  setenv("GDK_BACKEND", "x11", 0);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
