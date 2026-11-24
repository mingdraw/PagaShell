#ifndef PAGASHELL_LINUX_SYSTEM_TRAY_H_
#define PAGASHELL_LINUX_SYSTEM_TRAY_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

void RegisterSystemTray(FlView* view, GtkWindow* window);

#endif  // PAGASHELL_LINUX_SYSTEM_TRAY_H_
