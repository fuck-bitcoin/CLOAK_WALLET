#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    // Check if we're running XWayland (Wayland session with forced X11 backend).
    // XWayland + GtkHeaderBar CSD has a geometry mismatch that causes a ~56px
    // black bar at the bottom. Use server-side decorations (SSD) on XWayland
    // to avoid this — the WM draws the title bar instead.
    const gchar* wayland_display = g_getenv("WAYLAND_DISPLAY");
    if (g_strcmp0(wm_name, "GNOME Shell") != 0 || wayland_display != NULL) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "CLOAK");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "CLOAK");
  }

  // Calculate window size based on monitor dimensions
  // Target: phone-like aspect ratio that fits on screen
  GdkDisplay* display = gdk_display_get_default();
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == NULL) {
    // Fallback to first monitor if no primary
    monitor = gdk_display_get_monitor(display, 0);
  }

  gint window_width = 390;   // Phone-like width
  gint window_height = 780;  // Reduced from 844 to fit better

  if (monitor != NULL) {
    GdkRectangle workarea;
    gdk_monitor_get_workarea(monitor, &workarea);

    // Use 90% of available workarea height (accounts for taskbar/panel)
    gint max_height = (gint)(workarea.height * 0.90);
    if (max_height < window_height) {
      window_height = max_height;
    }
    // Ensure at least 600px height for usability
    if (window_height < 600) {
      window_height = 600;
    }
  }

  gtk_window_set_default_size(window, window_width, window_height);
  // Prevent maximize/fullscreen — this is a phone-like wallet, not a desktop app
  gtk_window_set_resizable(window, TRUE);
  g_signal_connect(window, "window-state-event",
                   G_CALLBACK(+[](GtkWidget* widget, GdkEventWindowState* event, gpointer) -> gboolean {
                     if (event->changed_mask & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) {
                       if (event->new_window_state & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) {
                         // Unmaximize/unfullscreen on next idle to avoid re-entrancy
                         g_idle_add(+[](gpointer data) -> gboolean {
                           GtkWindow* win = GTK_WINDOW(data);
                           gtk_window_unmaximize(win);
                           gtk_window_unfullscreen(win);
                           return G_SOURCE_REMOVE;
                         }, widget);
                       }
                     }
                     return FALSE;
                   }), NULL);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
