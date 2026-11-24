#include "system_tray.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gio.h>
#include <glib.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr const char* kKdeWatcher = "org.kde.StatusNotifierWatcher";
constexpr const char* kCanonicalWatcher = "com.canonical.StatusNotifierWatcher";
constexpr const char* kSniPath = "/StatusNotifierItem";
constexpr const char* kSniInterface = "org.kde.StatusNotifierItem";
constexpr const char* kMenuPath = "/StatusNotifierItem/Menu";
constexpr const char* kMenuInterface = "com.canonical.dbusmenu";

const char kSniIntrospectionXml[] =
    "<node>"
    "  <interface name='org.kde.StatusNotifierItem'>"
    "    <property name='Category'            type='s'           access='read'/>"
    "    <property name='Id'                  type='s'           access='read'/>"
    "    <property name='Title'               type='s'           access='read'/>"
    "    <property name='Status'              type='s'           access='read'/>"
    "    <property name='WindowId'            type='i'           access='read'/>"
    "    <property name='IconName'            type='s'           access='read'/>"
    "    <property name='IconPixmap'          type='a(iiay)'     access='read'/>"
    "    <property name='OverlayIconName'     type='s'           access='read'/>"
    "    <property name='OverlayIconPixmap'   type='a(iiay)'     access='read'/>"
    "    <property name='AttentionIconName'   type='s'           access='read'/>"
    "    <property name='AttentionIconPixmap' type='a(iiay)'     access='read'/>"
    "    <property name='AttentionMovieName'  type='s'           access='read'/>"
    "    <property name='ToolTip'             type='(sa(iiay)ss)' access='read'/>"
    "    <property name='ItemIsMenu'          type='b'           access='read'/>"
    "    <property name='Menu'                type='o'           access='read'/>"
    "    <method name='ContextMenu'>"
    "      <arg type='i' direction='in' name='x'/>"
    "      <arg type='i' direction='in' name='y'/>"
    "    </method>"
    "    <method name='Activate'>"
    "      <arg type='i' direction='in' name='x'/>"
    "      <arg type='i' direction='in' name='y'/>"
    "    </method>"
    "    <method name='SecondaryActivate'>"
    "      <arg type='i' direction='in' name='x'/>"
    "      <arg type='i' direction='in' name='y'/>"
    "    </method>"
    "    <method name='Scroll'>"
    "      <arg type='i' direction='in' name='delta'/>"
    "      <arg type='s' direction='in' name='orientation'/>"
    "    </method>"
    "    <signal name='NewTitle'/>"
    "    <signal name='NewIcon'/>"
    "    <signal name='NewAttentionIcon'/>"
    "    <signal name='NewOverlayIcon'/>"
    "    <signal name='NewToolTip'/>"
    "    <signal name='NewStatus'>"
    "      <arg type='s' name='status'/>"
    "    </signal>"
    "  </interface>"
    "</node>";

const char kDbusMenuIntrospectionXml[] =
    "<node>"
    "  <interface name='com.canonical.dbusmenu'>"
    "    <property name='Version'       type='u'  access='read'/>"
    "    <property name='TextDirection' type='s'  access='read'/>"
    "    <property name='Status'        type='s'  access='read'/>"
    "    <property name='IconThemePath' type='as' access='read'/>"
    "    <method name='GetLayout'>"
    "      <arg type='i'          direction='in'  name='parentId'/>"
    "      <arg type='i'          direction='in'  name='recursionDepth'/>"
    "      <arg type='as'         direction='in'  name='propertyNames'/>"
    "      <arg type='u'          direction='out' name='revision'/>"
    "      <arg type='(ia{sv}av)' direction='out' name='layout'/>"
    "    </method>"
    "    <method name='GetGroupProperties'>"
    "      <arg type='ai'         direction='in'  name='ids'/>"
    "      <arg type='as'         direction='in'  name='propertyNames'/>"
    "      <arg type='a(ia{sv})'  direction='out' name='properties'/>"
    "    </method>"
    "    <method name='GetProperty'>"
    "      <arg type='i' direction='in'  name='id'/>"
    "      <arg type='s' direction='in'  name='name'/>"
    "      <arg type='v' direction='out' name='value'/>"
    "    </method>"
    "    <method name='Event'>"
    "      <arg type='i' direction='in' name='id'/>"
    "      <arg type='s' direction='in' name='eventId'/>"
    "      <arg type='v' direction='in' name='data'/>"
    "      <arg type='u' direction='in' name='timestamp'/>"
    "    </method>"
    "    <method name='EventGroup'>"
    "      <arg type='a(isvu)' direction='in'  name='events'/>"
    "      <arg type='ai'      direction='out' name='idErrors'/>"
    "    </method>"
    "    <method name='AboutToShow'>"
    "      <arg type='i' direction='in'  name='id'/>"
    "      <arg type='b' direction='out' name='needUpdate'/>"
    "    </method>"
    "    <method name='AboutToShowGroup'>"
    "      <arg type='ai' direction='in'  name='ids'/>"
    "      <arg type='ai' direction='out' name='updatesNeeded'/>"
    "      <arg type='ai' direction='out' name='idErrors'/>"
    "    </method>"
    "    <signal name='ItemsPropertiesUpdated'>"
    "      <arg type='a(ia{sv})' name='updatedProps'/>"
    "      <arg type='a(ias)'    name='removedProps'/>"
    "    </signal>"
    "    <signal name='LayoutUpdated'>"
    "      <arg type='u' name='revision'/>"
    "      <arg type='i' name='parent'/>"
    "    </signal>"
    "    <signal name='ItemActivationRequested'>"
    "      <arg type='i' name='id'/>"
    "      <arg type='u' name='timestamp'/>"
    "    </signal>"
    "  </interface>"
    "</node>";

struct MenuItem {
  gint32 dbus_id = 0;
  std::string action_id;
  std::string label;
  std::string kind;
  bool enabled = true;
  bool checked = false;
  std::vector<MenuItem> children;
};

std::string ReadStringField(FlValue* map, const char* key,
                            const std::string& fallback = std::string()) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
    const gchar* raw = fl_value_get_string(value);
    return raw ? std::string(raw) : fallback;
  }
  return fallback;
}

bool ReadBoolField(FlValue* map, const char* key, bool fallback) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL) {
    return fl_value_get_bool(value) == TRUE;
  }
  return fallback;
}

std::string EscapeDbusMenuLabel(const std::string& label) {
  std::string escaped;
  escaped.reserve(label.size());
  for (size_t i = 0; i < label.size(); ++i) {
    if (label[i] == '_') {
      escaped.push_back('_');
    }
    escaped.push_back(label[i]);
  }
  return escaped;
}

GVariant* BuildEmptyPixmapArray() {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a(iiay)"));
  return g_variant_builder_end(&builder);
}

GVariant* BuildIconPixmapsVariant(const std::vector<GdkPixbuf*>& pixbufs) {
  GVariantBuilder array_builder;
  g_variant_builder_init(&array_builder, G_VARIANT_TYPE("a(iiay)"));
  for (size_t i = 0; i < pixbufs.size(); ++i) {
    GdkPixbuf* pixbuf = pixbufs[i];
    if (!pixbuf) continue;
    const int width = gdk_pixbuf_get_width(pixbuf);
    const int height = gdk_pixbuf_get_height(pixbuf);
    const int rowstride = gdk_pixbuf_get_rowstride(pixbuf);
    const int n_channels = gdk_pixbuf_get_n_channels(pixbuf);
    if (width <= 0 || height <= 0 || n_channels < 3) continue;
    const gboolean has_alpha = gdk_pixbuf_get_has_alpha(pixbuf);
    const guchar* pixels = gdk_pixbuf_get_pixels(pixbuf);
    std::vector<uint8_t> argb;
    argb.reserve(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
    for (int row = 0; row < height; ++row) {
      const guchar* p = pixels + row * rowstride;
      for (int col = 0; col < width; ++col) {
        const uint8_t r = p[0];
        const uint8_t g = p[1];
        const uint8_t b = p[2];
        const uint8_t a = has_alpha ? p[3] : 255u;
        argb.push_back(a);
        argb.push_back(r);
        argb.push_back(g);
        argb.push_back(b);
        p += n_channels;
      }
    }
    GVariantBuilder entry_builder;
    g_variant_builder_init(&entry_builder, G_VARIANT_TYPE("(iiay)"));
    g_variant_builder_add(&entry_builder, "i", width);
    g_variant_builder_add(&entry_builder, "i", height);
    g_variant_builder_add_value(
        &entry_builder,
        g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, argb.data(), argb.size(),
                                  sizeof(uint8_t)));
    g_variant_builder_add_value(&array_builder,
                                g_variant_builder_end(&entry_builder));
  }
  return g_variant_builder_end(&array_builder);
}

std::string ResolveBundleDataPath(const char* filename) {
  g_autofree gchar* executable_path =
      g_file_read_link("/proc/self/exe", nullptr);
  if (!executable_path) return std::string();
  g_autofree gchar* bundle_dir = g_path_get_dirname(executable_path);
  g_autofree gchar* file_path =
      g_build_filename(bundle_dir, "data", filename, nullptr);
  if (file_path && g_file_test(file_path, G_FILE_TEST_IS_REGULAR)) {
    return std::string(file_path);
  }
  return std::string();
}

bool ContainsCaseInsensitive(const char* haystack, const char* needle) {
  if (!haystack || !needle || !*needle) return false;
  g_autofree gchar* lower = g_ascii_strdown(haystack, -1);
  return g_strstr_len(lower, -1, needle) != nullptr;
}

bool ShouldUseDarkTrayIcon() {
  const gchar* desktop = g_getenv("XDG_CURRENT_DESKTOP");
  if (desktop && (ContainsCaseInsensitive(desktop, "gnome") ||
                  ContainsCaseInsensitive(desktop, "ubuntu") ||
                  ContainsCaseInsensitive(desktop, "hyprland") ||
                  ContainsCaseInsensitive(desktop, "sway") ||
                  ContainsCaseInsensitive(desktop, "i3"))) {
    return false;
  }
  GtkSettings* settings = gtk_settings_get_default();
  if (!settings) return false;
  gboolean prefer_dark = FALSE;
  g_autofree gchar* theme_name = nullptr;
  g_object_get(settings, "gtk-application-prefer-dark-theme", &prefer_dark,
               "gtk-theme-name", &theme_name, nullptr);
  if (prefer_dark || ContainsCaseInsensitive(theme_name, "dark")) {
    return false;
  }
  return true;
}

bool IsX11Display() {
#ifdef GDK_WINDOWING_X11
  GdkDisplay* display = gdk_display_get_default();
  return display != nullptr && GDK_IS_X11_DISPLAY(display);
#else
  return false;
#endif
}

class LinuxSystemTray : public std::enable_shared_from_this<LinuxSystemTray> {
 public:
  explicit LinuxSystemTray(FlMethodChannel* channel)
      : channel_(channel), tooltip_("PagaShell") {}

  ~LinuxSystemTray() { Dispose(); }

  void HandleMethodCall(FlMethodCall* call) {
    const gchar* method = fl_method_call_get_name(call);
    if (g_strcmp0(method, "initialize") == 0) {
      Initialize();
      fl_method_call_respond_success(call, nullptr, nullptr);
      return;
    }
    if (g_strcmp0(method, "update") == 0) {
      FlValue* args = fl_method_call_get_args(call);
      if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
        fl_method_call_respond_error(call, "tray_invalid",
                                     "Invalid tray payload", nullptr, nullptr);
        return;
      }
      if (!initialized_) {
        Initialize();
      }
      UpdateFromArgs(args);
      fl_method_call_respond_success(call, nullptr, nullptr);
      return;
    }
    if (g_strcmp0(method, "setBackgroundMode") == 0) {
      fl_method_call_respond_success(call, nullptr, nullptr);
      return;
    }
    if (g_strcmp0(method, "dispose") == 0) {
      Dispose();
      fl_method_call_respond_success(call, nullptr, nullptr);
      return;
    }
    fl_method_call_respond_not_implemented(call, nullptr);
  }

  void Dispose() {
    if (disposed_) return;
    disposed_ = true;

    DestroyFallbackIcon();
    ClosePopupMenu();

    if (kde_watch_id_ != 0) {
      g_bus_unwatch_name(kde_watch_id_);
      kde_watch_id_ = 0;
    }
    if (canonical_watch_id_ != 0) {
      g_bus_unwatch_name(canonical_watch_id_);
      canonical_watch_id_ = 0;
    }
    if (name_owner_id_ != 0) {
      g_bus_unown_name(name_owner_id_);
      name_owner_id_ = 0;
    }
    if (connection_ && sni_registration_id_ != 0) {
      g_dbus_connection_unregister_object(connection_, sni_registration_id_);
      sni_registration_id_ = 0;
    }
    if (connection_ && menu_registration_id_ != 0) {
      g_dbus_connection_unregister_object(connection_, menu_registration_id_);
      menu_registration_id_ = 0;
    }
    if (connection_) {
      g_dbus_connection_flush_sync(connection_, nullptr, nullptr);
      g_dbus_connection_close_sync(connection_, nullptr, nullptr);
      g_object_unref(connection_);
      connection_ = nullptr;
    }
    if (settings_) {
      g_signal_handlers_disconnect_by_data(settings_, this);
      g_object_unref(settings_);
      settings_ = nullptr;
    }
    ClearIcons();
    items_.clear();
    node_by_id_.clear();
    channel_ = nullptr;
  }

 private:
  void Initialize() {
    if (disposed_ || initialized_) return;
    initialized_ = true;
    LoadIcons();
    WatchThemeChanges();
    if (!InitSniDbus()) {
      EnsureFallbackIcon();
    }
  }

  void ClearIcons() {
    for (size_t i = 0; i < icon_pixbufs_.size(); ++i) {
      if (icon_pixbufs_[i]) g_object_unref(icon_pixbufs_[i]);
    }
    icon_pixbufs_.clear();
  }

  void LoadIcons() {
    ClearIcons();
    using_dark_icon_ = ShouldUseDarkTrayIcon();
    const char* primary[2] = {
        using_dark_icon_ ? "tray_icon_dark_24.png" : "tray_icon_light_24.png",
        using_dark_icon_ ? "tray_icon_dark_48.png" : "tray_icon_light_48.png",
    };
    for (int i = 0; i < 2; ++i) {
      const std::string path = ResolveBundleDataPath(primary[i]);
      if (path.empty()) continue;
      GdkPixbuf* pb = gdk_pixbuf_new_from_file(path.c_str(), nullptr);
      if (pb) icon_pixbufs_.push_back(pb);
    }
    if (!icon_pixbufs_.empty()) return;

    const std::string fallback = ResolveBundleDataPath("app_icon.png");
    if (fallback.empty()) return;
    const int sizes[2] = {24, 48};
    for (int i = 0; i < 2; ++i) {
      GdkPixbuf* pb = gdk_pixbuf_new_from_file_at_scale(
          fallback.c_str(), sizes[i], sizes[i], TRUE, nullptr);
      if (pb) icon_pixbufs_.push_back(pb);
    }
  }

  void WatchThemeChanges() {
    if (settings_) return;
    GtkSettings* settings = gtk_settings_get_default();
    if (!settings) return;
    settings_ = GTK_SETTINGS(g_object_ref(settings));
    g_signal_connect(
        settings_, "notify::gtk-application-prefer-dark-theme",
        G_CALLBACK(&LinuxSystemTray::OnThemeSettingChanged), this);
    g_signal_connect(
        settings_, "notify::gtk-theme-name",
        G_CALLBACK(&LinuxSystemTray::OnThemeSettingChanged), this);
  }

  static void OnThemeSettingChanged(GObject*, GParamSpec*, gpointer data) {
    auto* self = static_cast<LinuxSystemTray*>(data);
    if (!self || self->disposed_) return;
    self->ReloadIcons();
  }

  void ReloadIcons() {
    if (ShouldUseDarkTrayIcon() == using_dark_icon_ && !icon_pixbufs_.empty()) {
      return;
    }
    LoadIcons();
    EmitSniSignal("NewIcon");
    if (fallback_icon_ && !icon_pixbufs_.empty()) {
      G_GNUC_BEGIN_IGNORE_DEPRECATIONS
      gtk_status_icon_set_from_pixbuf(fallback_icon_, icon_pixbufs_[0]);
      G_GNUC_END_IGNORE_DEPRECATIONS
    }
  }

  bool InitSniDbus() {
    g_autofree gchar* address =
        g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    if (!address) return false;
    connection_ = g_dbus_connection_new_for_address_sync(
        address,
        static_cast<GDBusConnectionFlags>(
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, nullptr);
    if (!connection_) return false;
    g_dbus_connection_set_exit_on_close(connection_, FALSE);

    static std::atomic<int> next_index{1};
    service_name_ = "org.kde.StatusNotifierItem-" +
                    std::to_string(static_cast<long>(getpid())) + "-" +
                    std::to_string(next_index++);

    GDBusNodeInfo* sni_node =
        g_dbus_node_info_new_for_xml(kSniIntrospectionXml, nullptr);
    if (!sni_node) return false;
    GDBusInterfaceInfo* sni_iface =
        g_dbus_node_info_lookup_interface(sni_node, kSniInterface);
    static const GDBusInterfaceVTable sni_vtable = []() {
      GDBusInterfaceVTable table{};
      table.method_call = &LinuxSystemTray::OnSniMethodCall;
      table.get_property = &LinuxSystemTray::OnSniGetProperty;
      return table;
    }();
    sni_registration_id_ = g_dbus_connection_register_object(
        connection_, kSniPath, sni_iface, &sni_vtable, this, nullptr, nullptr);
    g_dbus_node_info_unref(sni_node);
    if (sni_registration_id_ == 0) return false;

    GDBusNodeInfo* menu_node =
        g_dbus_node_info_new_for_xml(kDbusMenuIntrospectionXml, nullptr);
    if (!menu_node) return false;
    GDBusInterfaceInfo* menu_iface =
        g_dbus_node_info_lookup_interface(menu_node, kMenuInterface);
    static const GDBusInterfaceVTable menu_vtable = []() {
      GDBusInterfaceVTable table{};
      table.method_call = &LinuxSystemTray::OnMenuMethodCall;
      table.get_property = &LinuxSystemTray::OnMenuGetProperty;
      return table;
    }();
    menu_registration_id_ = g_dbus_connection_register_object(
        connection_, kMenuPath, menu_iface, &menu_vtable, this, nullptr,
        nullptr);
    g_dbus_node_info_unref(menu_node);
    if (menu_registration_id_ == 0) return false;

    name_owner_id_ = g_bus_own_name_on_connection(
        connection_, service_name_.c_str(), G_BUS_NAME_OWNER_FLAGS_NONE,
        &LinuxSystemTray::OnNameAcquired, &LinuxSystemTray::OnNameLost, this,
        nullptr);
    kde_watch_id_ = g_bus_watch_name_on_connection(
        connection_, kKdeWatcher, G_BUS_NAME_WATCHER_FLAGS_NONE,
        &LinuxSystemTray::OnKdeWatcherAppeared,
        &LinuxSystemTray::OnKdeWatcherVanished, this, nullptr);
    canonical_watch_id_ = g_bus_watch_name_on_connection(
        connection_, kCanonicalWatcher, G_BUS_NAME_WATCHER_FLAGS_NONE,
        &LinuxSystemTray::OnCanonicalWatcherAppeared,
        &LinuxSystemTray::OnCanonicalWatcherVanished, this, nullptr);
    return true;
  }

  void RegisterWithWatcherAsync(const char* watcher_name) {
    if (disposed_ || !connection_ || !name_acquired_) return;
    auto* weak = new std::weak_ptr<LinuxSystemTray>(shared_from_this());
    g_dbus_connection_call(
        connection_, watcher_name, "/StatusNotifierWatcher", watcher_name,
        "RegisterStatusNotifierItem",
        g_variant_new("(s)", service_name_.c_str()), nullptr,
        G_DBUS_CALL_FLAGS_NONE, 2000, nullptr,
        &LinuxSystemTray::OnRegisterWatcherFinished, weak);
  }

  static void OnRegisterWatcherFinished(GObject* source, GAsyncResult* res,
                                        gpointer user_data) {
    std::unique_ptr<std::weak_ptr<LinuxSystemTray>> weak(
        static_cast<std::weak_ptr<LinuxSystemTray>*>(user_data));
    GError* error = nullptr;
    GVariant* reply =
        g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, &error);
    if (reply) g_variant_unref(reply);
    auto self = weak->lock();
    if (!self || self->disposed_) {
      if (error) g_error_free(error);
      return;
    }
    if (!error) {
      self->sni_registered_ = true;
      self->DestroyFallbackIcon();
    } else {
      g_error_free(error);
      if (!self->sni_registered_ && !self->kde_watcher_present_ &&
          !self->canonical_watcher_present_) {
        self->EnsureFallbackIcon();
      }
    }
  }

  static void OnNameAcquired(GDBusConnection*, const gchar*, gpointer data) {
    auto* self = static_cast<LinuxSystemTray*>(data);
    if (!self || self->disposed_) return;
    self->name_acquired_ = true;
    if (self->kde_watcher_present_) {
      self->RegisterWithWatcherAsync(kKdeWatcher);
    } else if (self->canonical_watcher_present_) {
      self->RegisterWithWatcherAsync(kCanonicalWatcher);
    }
  }

  static void OnNameLost(GDBusConnection*, const gchar*, gpointer data) {
    auto* self = static_cast<LinuxSystemTray*>(data);
    if (self) self->name_acquired_ = false;
  }

  static void OnKdeWatcherAppeared(GDBusConnection*, const gchar*, const gchar*,
                                   gpointer data) {
    auto* self = static_cast<LinuxSystemTray*>(data);
    if (!self || self->disposed_) return;
    self->kde_watcher_present_ = true;
    self->RegisterWithWatcherAsync(kKdeWatcher);
  }

  static void OnKdeWatcherVanished(GDBusConnection*, const gchar*,
                                   gpointer data) {
    auto* self = static_cast<LinuxSystemTray*>(data);
    if (!self || self->disposed_) return;
    self->kde_watcher_present_ = false;
    if (!self->canonical_watcher_present_) {
      self->sni_registered_ = false;
      self->EnsureFallbackIcon();
    }
  }

  static void OnCanonicalWatcherAppeared(GDBusConnection*, const gchar*,
                                         const gchar*, gpointer data) {
    auto* self = static_cast<LinuxSystemTray*>(data);
    if (!self || self->disposed_) return;
    self->canonical_watcher_present_ = true;
    if (!self->kde_watcher_present_) {
      self->RegisterWithWatcherAsync(kCanonicalWatcher);
    }
  }

  static void OnCanonicalWatcherVanished(GDBusConnection*, const gchar*,
                                         gpointer data) {
    auto* self = static_cast<LinuxSystemTray*>(data);
    if (!self || self->disposed_) return;
    self->canonical_watcher_present_ = false;
    if (!self->kde_watcher_present_) {
      self->sni_registered_ = false;
      self->EnsureFallbackIcon();
    }
  }

  void UpdateFromArgs(FlValue* args) {
    tooltip_ = ReadStringField(args, "tooltip", "PagaShell");
    if (tooltip_.empty()) tooltip_ = "PagaShell";

    items_.clear();
    node_by_id_.clear();
    gint32 next_id = 1;
    FlValue* raw_items = fl_value_lookup_string(args, "items");
    if (raw_items && fl_value_get_type(raw_items) == FL_VALUE_TYPE_LIST) {
      items_ = ParseMenuItems(raw_items, &next_id);
    }
    IndexMenuItems(items_);
    ++menu_revision_;

    EmitSniSignal("NewToolTip");
    if (connection_ && menu_registration_id_ != 0) {
      g_dbus_connection_emit_signal(
          connection_, nullptr, kMenuPath, kMenuInterface, "LayoutUpdated",
          g_variant_new("(ui)", menu_revision_, static_cast<gint32>(0)),
          nullptr);
    }
    UpdateFallbackTooltip();
  }

  std::vector<MenuItem> ParseMenuItems(FlValue* list, gint32* next_id) {
    std::vector<MenuItem> result;
    const size_t count = fl_value_get_length(list);
    result.reserve(count);
    for (size_t i = 0; i < count; ++i) {
      FlValue* entry = fl_value_get_list_value(list, i);
      if (!entry || fl_value_get_type(entry) != FL_VALUE_TYPE_MAP) continue;
      MenuItem item;
      item.dbus_id = (*next_id)++;
      item.action_id = ReadStringField(entry, "id");
      item.label = ReadStringField(entry, "label");
      item.kind = ReadStringField(entry, "kind", "normal");
      item.enabled = ReadBoolField(entry, "enabled", true);
      item.checked = ReadBoolField(entry, "checked", false);
      FlValue* raw_children = fl_value_lookup_string(entry, "children");
      if (raw_children &&
          fl_value_get_type(raw_children) == FL_VALUE_TYPE_LIST) {
        item.children = ParseMenuItems(raw_children, next_id);
      }
      result.push_back(std::move(item));
    }
    return result;
  }

  void IndexMenuItems(const std::vector<MenuItem>& list) {
    for (size_t i = 0; i < list.size(); ++i) {
      const MenuItem& item = list[i];
      node_by_id_[item.dbus_id] = &item;
      if (!item.children.empty()) {
        IndexMenuItems(item.children);
      }
    }
  }

  void EmitSniSignal(const char* signal_name, GVariant* params = nullptr) {
    if (disposed_ || !connection_ || sni_registration_id_ == 0) return;
    GError* error = nullptr;
    g_dbus_connection_emit_signal(connection_, nullptr, kSniPath, kSniInterface,
                                  signal_name, params, &error);
    if (error) g_error_free(error);
  }

  void EmitIconActivated() {
    if (disposed_ || !channel_) return;
    fl_method_channel_invoke_method(channel_, "onIconActivated", nullptr,
                                    nullptr, nullptr, nullptr);
  }

  void EmitMenuItemSelected(const std::string& action_id) {
    if (disposed_ || !channel_ || action_id.empty()) return;
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "id",
                             fl_value_new_string(action_id.c_str()));
    fl_method_channel_invoke_method(channel_, "onMenuItemSelected", args,
                                    nullptr, nullptr, nullptr);
  }

  static void OnSniMethodCall(GDBusConnection*, const gchar*, const gchar*,
                              const gchar*, const gchar* method_name, GVariant*,
                              GDBusMethodInvocation* invocation,
                              gpointer user_data) {
    auto* self = static_cast<LinuxSystemTray*>(user_data);
    if (!self || self->disposed_) {
      g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                            G_DBUS_ERROR_FAILED,
                                            "Tray disposed");
      return;
    }
    if (g_strcmp0(method_name, "Activate") == 0) {
      g_dbus_method_invocation_return_value(invocation, nullptr);
      self->EmitIconActivated();
      return;
    }
    if (g_strcmp0(method_name, "ContextMenu") == 0) {
      g_dbus_method_invocation_return_value(invocation, nullptr);
      self->ShowGtkPopupMenu(0, gtk_get_current_event_time());
      return;
    }
    if (g_strcmp0(method_name, "SecondaryActivate") == 0 ||
        g_strcmp0(method_name, "Scroll") == 0) {
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    g_dbus_method_invocation_return_error(
        invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
        "Unknown SNI method: %s", method_name);
  }

  static GVariant* OnSniGetProperty(GDBusConnection*, const gchar*,
                                    const gchar*, const gchar*,
                                    const gchar* property_name, GError** error,
                                    gpointer user_data) {
    auto* self = static_cast<LinuxSystemTray*>(user_data);
    if (!self || self->disposed_) return nullptr;

    if (g_strcmp0(property_name, "Category") == 0) {
      return g_variant_new_string("ApplicationStatus");
    }
    if (g_strcmp0(property_name, "Id") == 0) {
      return g_variant_new_string(APPLICATION_ID);
    }
    if (g_strcmp0(property_name, "Title") == 0) {
      return g_variant_new_string("PagaShell");
    }
    if (g_strcmp0(property_name, "Status") == 0) {
      return g_variant_new_string("Active");
    }
    if (g_strcmp0(property_name, "WindowId") == 0) {
      return g_variant_new_int32(0);
    }
    if (g_strcmp0(property_name, "IconName") == 0) {
      return g_variant_new_string(
          self->icon_pixbufs_.empty() ? APPLICATION_ID : "");
    }
    if (g_strcmp0(property_name, "IconPixmap") == 0) {
      return BuildIconPixmapsVariant(self->icon_pixbufs_);
    }
    if (g_strcmp0(property_name, "OverlayIconName") == 0 ||
        g_strcmp0(property_name, "AttentionIconName") == 0 ||
        g_strcmp0(property_name, "AttentionMovieName") == 0) {
      return g_variant_new_string("");
    }
    if (g_strcmp0(property_name, "OverlayIconPixmap") == 0 ||
        g_strcmp0(property_name, "AttentionIconPixmap") == 0) {
      return BuildEmptyPixmapArray();
    }
    if (g_strcmp0(property_name, "ToolTip") == 0) {
      return g_variant_new("(s@a(iiay)ss)", "", BuildEmptyPixmapArray(),
                           self->tooltip_.c_str(), "");
    }
    if (g_strcmp0(property_name, "ItemIsMenu") == 0) {
      return g_variant_new_boolean(FALSE);
    }
    if (g_strcmp0(property_name, "Menu") == 0) {
      return g_variant_new_object_path(kMenuPath);
    }
    if (error) {
      *error = g_error_new(G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
                           "Unknown SNI property: %s", property_name);
    }
    return nullptr;
  }

  static void AppendDbusMenuProps(GVariantBuilder* props,
                                  const MenuItem* item) {
    if (!item) {
      g_variant_builder_add(props, "{sv}", "children-display",
                            g_variant_new_string("submenu"));
      return;
    }
    g_variant_builder_add(props, "{sv}", "visible",
                          g_variant_new_boolean(TRUE));
    if (item->kind == "separator") {
      g_variant_builder_add(props, "{sv}", "type",
                            g_variant_new_string("separator"));
      g_variant_builder_add(props, "{sv}", "enabled",
                            g_variant_new_boolean(FALSE));
      return;
    }
    const bool clickable =
        item->enabled && (item->kind == "submenu" || !item->action_id.empty());
    g_variant_builder_add(props, "{sv}", "enabled",
                          g_variant_new_boolean(clickable ? TRUE : FALSE));
    const std::string escaped = EscapeDbusMenuLabel(item->label);
    g_variant_builder_add(props, "{sv}", "label",
                          g_variant_new_string(escaped.c_str()));
    if (item->kind == "checkbox") {
      g_variant_builder_add(props, "{sv}", "toggle-type",
                            g_variant_new_string("checkmark"));
      g_variant_builder_add(props, "{sv}", "toggle-state",
                            g_variant_new_int32(item->checked ? 1 : 0));
    }
    if (item->kind == "submenu") {
      g_variant_builder_add(props, "{sv}", "children-display",
                            g_variant_new_string("submenu"));
    }
  }

  GVariant* BuildLayoutNode(gint32 node_id, const MenuItem* item,
                            const std::vector<MenuItem>* children,
                            gint32 depth) const {
    GVariantBuilder props;
    GVariantBuilder child_builder;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_init(&child_builder, G_VARIANT_TYPE("av"));
    AppendDbusMenuProps(&props, item);

    if (children && (depth < 0 || depth > 0)) {
      const gint32 next_depth = depth < 0 ? -1 : depth - 1;
      for (size_t i = 0; i < children->size(); ++i) {
        const MenuItem& child = (*children)[i];
        const std::vector<MenuItem>* grand =
            child.kind == "submenu" ? &child.children : nullptr;
        g_variant_builder_add(
            &child_builder, "v",
            BuildLayoutNode(child.dbus_id, &child, grand, next_depth));
      }
    }

    return g_variant_new("(i@a{sv}@av)", node_id, g_variant_builder_end(&props),
                         g_variant_builder_end(&child_builder));
  }

  static void OnMenuMethodCall(GDBusConnection*, const gchar*, const gchar*,
                               const gchar*, const gchar* method_name,
                               GVariant* parameters,
                               GDBusMethodInvocation* invocation,
                               gpointer user_data) {
    auto* self = static_cast<LinuxSystemTray*>(user_data);
    if (!self || self->disposed_) {
      g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                            G_DBUS_ERROR_FAILED,
                                            "Tray disposed");
      return;
    }

    if (g_strcmp0(method_name, "GetLayout") == 0) {
      gint32 parent_id = 0;
      gint32 depth = -1;
      GVariantIter* prop_names = nullptr;
      if (parameters) {
        g_variant_get(parameters, "(iias)", &parent_id, &depth, &prop_names);
        if (prop_names) g_variant_iter_free(prop_names);
      }
      GVariant* layout = nullptr;
      if (parent_id == 0) {
        layout = self->BuildLayoutNode(0, nullptr, &self->items_, depth);
      } else {
        auto it = self->node_by_id_.find(parent_id);
        if (it != self->node_by_id_.end()) {
          const MenuItem* item = it->second;
          const std::vector<MenuItem>* children =
              item->kind == "submenu" ? &item->children : nullptr;
          layout = self->BuildLayoutNode(parent_id, item, children, depth);
        } else {
          layout = self->BuildLayoutNode(parent_id, nullptr, nullptr, 0);
        }
      }
      g_dbus_method_invocation_return_value(
          invocation,
          g_variant_new("(u@(ia{sv}av))", self->menu_revision_, layout));
      return;
    }

    if (g_strcmp0(method_name, "GetGroupProperties") == 0) {
      GVariantIter* ids = nullptr;
      GVariantIter* prop_names = nullptr;
      if (parameters) {
        g_variant_get(parameters, "(aias)", &ids, &prop_names);
      }
      GVariantBuilder result;
      g_variant_builder_init(&result, G_VARIANT_TYPE("a(ia{sv})"));
      if (ids) {
        gint32 item_id = 0;
        while (g_variant_iter_loop(ids, "i", &item_id)) {
          GVariantBuilder props;
          g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
          if (item_id == 0) {
            AppendDbusMenuProps(&props, nullptr);
          } else {
            auto it = self->node_by_id_.find(item_id);
            if (it != self->node_by_id_.end()) {
              AppendDbusMenuProps(&props, it->second);
            }
          }
          g_variant_builder_add_value(
              &result,
              g_variant_new("(i@a{sv})", item_id,
                            g_variant_builder_end(&props)));
        }
        g_variant_iter_free(ids);
      }
      if (prop_names) g_variant_iter_free(prop_names);
      g_dbus_method_invocation_return_value(
          invocation,
          g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&result)));
      return;
    }

    if (g_strcmp0(method_name, "GetProperty") == 0) {
      gint32 item_id = 0;
      const gchar* name = nullptr;
      if (parameters) {
        g_variant_get(parameters, "(i&s)", &item_id, &name);
      }
      GVariantBuilder props;
      g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
      if (item_id == 0) {
        AppendDbusMenuProps(&props, nullptr);
      } else {
        auto it = self->node_by_id_.find(item_id);
        if (it != self->node_by_id_.end()) {
          AppendDbusMenuProps(&props, it->second);
        }
      }
      GVariant* dict = g_variant_ref_sink(g_variant_builder_end(&props));
      GVariant* value =
          g_variant_lookup_value(dict, name ? name : "", nullptr);
      g_variant_unref(dict);
      g_dbus_method_invocation_return_value(
          invocation,
          g_variant_new("(@v)",
                        value ? g_variant_new_variant(value)
                              : g_variant_new_variant(g_variant_new_string(""))));
      if (value) g_variant_unref(value);
      return;
    }

    if (g_strcmp0(method_name, "Event") == 0) {
      gint32 item_id = 0;
      const gchar* event_id = nullptr;
      GVariant* data = nullptr;
      guint32 timestamp = 0;
      if (parameters) {
        g_variant_get(parameters, "(i&svu)", &item_id, &event_id, &data,
                      &timestamp);
        if (data) g_variant_unref(data);
      }
      const std::string event = event_id ? std::string(event_id) : std::string();
      g_dbus_method_invocation_return_value(invocation, nullptr);
      self->DispatchDbusMenuEvent(item_id, event);
      return;
    }

    if (g_strcmp0(method_name, "EventGroup") == 0) {
      GVariantIter* events = nullptr;
      if (parameters) {
        g_variant_get(parameters, "(a(isvu))", &events);
      }
      std::vector<std::pair<gint32, std::string>> received;
      if (events) {
        gint32 item_id = 0;
        const gchar* event_id = nullptr;
        GVariant* data = nullptr;
        guint32 timestamp = 0;
        while (g_variant_iter_loop(events, "(i&svu)", &item_id, &event_id,
                                   &data, &timestamp)) {
          received.push_back(std::make_pair(
              item_id, event_id ? std::string(event_id) : std::string()));
        }
        g_variant_iter_free(events);
      }
      GVariantBuilder errors;
      g_variant_builder_init(&errors, G_VARIANT_TYPE("ai"));
      g_dbus_method_invocation_return_value(
          invocation, g_variant_new("(@ai)", g_variant_builder_end(&errors)));
      for (size_t i = 0; i < received.size(); ++i) {
        self->DispatchDbusMenuEvent(received[i].first, received[i].second);
      }
      return;
    }

    if (g_strcmp0(method_name, "AboutToShow") == 0) {
      g_dbus_method_invocation_return_value(invocation,
                                            g_variant_new("(b)", FALSE));
      return;
    }

    if (g_strcmp0(method_name, "AboutToShowGroup") == 0) {
      GVariantBuilder updates;
      GVariantBuilder errors;
      g_variant_builder_init(&updates, G_VARIANT_TYPE("ai"));
      g_variant_builder_init(&errors, G_VARIANT_TYPE("ai"));
      g_dbus_method_invocation_return_value(
          invocation, g_variant_new("(@ai@ai)", g_variant_builder_end(&updates),
                                    g_variant_builder_end(&errors)));
      return;
    }

    g_dbus_method_invocation_return_error(
        invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
        "Unknown dbusmenu method: %s", method_name);
  }

  static GVariant* OnMenuGetProperty(GDBusConnection*, const gchar*,
                                     const gchar*, const gchar*,
                                     const gchar* property_name, GError** error,
                                     gpointer) {
    if (g_strcmp0(property_name, "Version") == 0) {
      return g_variant_new_uint32(3);
    }
    if (g_strcmp0(property_name, "TextDirection") == 0) {
      return g_variant_new_string("ltr");
    }
    if (g_strcmp0(property_name, "Status") == 0) {
      return g_variant_new_string("normal");
    }
    if (g_strcmp0(property_name, "IconThemePath") == 0) {
      GVariantBuilder paths;
      g_variant_builder_init(&paths, G_VARIANT_TYPE("as"));
      return g_variant_builder_end(&paths);
    }
    if (error) {
      *error = g_error_new(G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
                           "Unknown dbusmenu property: %s", property_name);
    }
    return nullptr;
  }

  void DispatchDbusMenuEvent(gint32 item_id, const std::string& event) {
    if (event != "clicked" && event != "activated") return;
    auto it = node_by_id_.find(item_id);
    if (it == node_by_id_.end()) return;
    const MenuItem* item = it->second;
    if (!item->enabled || item->action_id.empty()) return;
    EmitMenuItemSelected(item->action_id);
  }

  // Fallback X11 tray icon for desktop environments without StatusNotifierWatcher.
  void EnsureFallbackIcon() {
    if (disposed_ || sni_registered_ || fallback_icon_ || !IsX11Display()) {
      return;
    }
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    if (!icon_pixbufs_.empty()) {
      fallback_icon_ = gtk_status_icon_new_from_pixbuf(icon_pixbufs_[0]);
    } else {
      fallback_icon_ = gtk_status_icon_new_from_icon_name(APPLICATION_ID);
    }
    if (!fallback_icon_) return;
    gtk_status_icon_set_title(fallback_icon_, "PagaShell");
    gtk_status_icon_set_tooltip_text(fallback_icon_, tooltip_.c_str());
    gtk_status_icon_set_visible(fallback_icon_, TRUE);

    g_signal_connect(
        fallback_icon_, "activate",
        G_CALLBACK(+[](GtkStatusIcon*, gpointer data) {
          auto* self = static_cast<LinuxSystemTray*>(data);
          if (self && !self->disposed_) self->EmitIconActivated();
        }),
        this);
    g_signal_connect(
        fallback_icon_, "popup-menu",
        G_CALLBACK(+[](GtkStatusIcon*, guint button, guint activate_time,
                       gpointer data) {
          auto* self = static_cast<LinuxSystemTray*>(data);
          if (self && !self->disposed_) {
            self->ShowGtkPopupMenu(button, activate_time);
          }
        }),
        this);
    G_GNUC_END_IGNORE_DEPRECATIONS
  }

  void UpdateFallbackTooltip() {
    if (!fallback_icon_) return;
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_status_icon_set_tooltip_text(fallback_icon_, tooltip_.c_str());
    G_GNUC_END_IGNORE_DEPRECATIONS
  }

  void DestroyFallbackIcon() {
    if (!fallback_icon_) return;
    g_signal_handlers_disconnect_by_data(fallback_icon_, this);
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_status_icon_set_visible(fallback_icon_, FALSE);
    G_GNUC_END_IGNORE_DEPRECATIONS
    g_object_unref(fallback_icon_);
    fallback_icon_ = nullptr;
  }

  void ClosePopupMenu() {
    if (!popup_menu_) return;
    gtk_menu_popdown(GTK_MENU(popup_menu_));
    gtk_widget_destroy(popup_menu_);
    popup_menu_ = nullptr;
  }

  struct MenuActionPayload {
    std::weak_ptr<LinuxSystemTray> tray;
    std::string action_id;
  };

  GtkWidget* BuildGtkMenu(const std::vector<MenuItem>& items) {
    GtkWidget* menu = gtk_menu_new();
    for (size_t i = 0; i < items.size(); ++i) {
      const MenuItem& item = items[i];
      if (item.kind == "separator") {
        gtk_menu_shell_append(GTK_MENU_SHELL(menu),
                              gtk_separator_menu_item_new());
        continue;
      }
      GtkWidget* widget = nullptr;
      if (item.kind == "checkbox") {
        widget = gtk_check_menu_item_new_with_label(item.label.c_str());
        gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(widget),
                                       item.checked ? TRUE : FALSE);
      } else {
        widget = gtk_menu_item_new_with_label(item.label.c_str());
      }
      if (item.kind == "submenu") {
        gtk_widget_set_sensitive(widget, item.enabled ? TRUE : FALSE);
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(widget),
                                  BuildGtkMenu(item.children));
      } else {
        const bool clickable = item.enabled && !item.action_id.empty();
        gtk_widget_set_sensitive(widget, clickable ? TRUE : FALSE);
        if (clickable) {
          auto* payload =
              new MenuActionPayload{shared_from_this(), item.action_id};
          g_signal_connect_data(
              widget, "activate",
              G_CALLBACK(+[](GtkMenuItem*, gpointer data) {
                auto* p = static_cast<MenuActionPayload*>(data);
                if (auto tray = p->tray.lock()) {
                  tray->EmitMenuItemSelected(p->action_id);
                }
              }),
              payload,
              +[](gpointer data, GClosure*) {
                delete static_cast<MenuActionPayload*>(data);
              },
              static_cast<GConnectFlags>(0));
        }
      }
      gtk_menu_shell_append(GTK_MENU_SHELL(menu), widget);
    }
    gtk_widget_show_all(menu);
    return menu;
  }

  void ShowGtkPopupMenu(guint button, guint32 activate_time) {
    if (disposed_ || items_.empty() || !IsX11Display()) return;
    ClosePopupMenu();
    popup_menu_ = BuildGtkMenu(items_);
    g_object_ref_sink(popup_menu_);
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_menu_popup(GTK_MENU(popup_menu_), nullptr, nullptr, nullptr, nullptr,
                   button, activate_time);
    G_GNUC_END_IGNORE_DEPRECATIONS
  }

  FlMethodChannel* channel_ = nullptr;
  std::string tooltip_;
  std::vector<MenuItem> items_;
  std::unordered_map<gint32, const MenuItem*> node_by_id_;
  std::vector<GdkPixbuf*> icon_pixbufs_;

  bool initialized_ = false;
  bool disposed_ = false;
  bool name_acquired_ = false;
  bool kde_watcher_present_ = false;
  bool canonical_watcher_present_ = false;
  bool sni_registered_ = false;
  bool using_dark_icon_ = false;

  GDBusConnection* connection_ = nullptr;
  guint sni_registration_id_ = 0;
  guint menu_registration_id_ = 0;
  guint name_owner_id_ = 0;
  guint kde_watch_id_ = 0;
  guint canonical_watch_id_ = 0;
  guint32 menu_revision_ = 1;
  std::string service_name_;

  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  GtkStatusIcon* fallback_icon_ = nullptr;
  G_GNUC_END_IGNORE_DEPRECATIONS
  GtkWidget* popup_menu_ = nullptr;
  GtkSettings* settings_ = nullptr;
};

struct TrayHolder {
  std::shared_ptr<LinuxSystemTray> tray;
};

void OnTrayMethodCall(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* holder = static_cast<TrayHolder*>(data);
  if (!holder || !holder->tray) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  std::shared_ptr<LinuxSystemTray> tray = holder->tray;
  tray->HandleMethodCall(call);
}

void OnWindowDestroyed(GtkWidget*, gpointer data) {
  auto* weak = static_cast<std::weak_ptr<LinuxSystemTray>*>(data);
  if (auto tray = weak->lock()) {
    tray->Dispose();
  }
}

void FreeWeakTray(gpointer data, GClosure*) {
  delete static_cast<std::weak_ptr<LinuxSystemTray>*>(data);
}

}  // namespace

void RegisterSystemTray(FlView* view, GtkWindow* window) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "pagashell/tray", FL_METHOD_CODEC(codec));
  auto tray = std::make_shared<LinuxSystemTray>(channel);
  auto* holder = new TrayHolder{tray};
  fl_method_channel_set_method_call_handler(
      channel, OnTrayMethodCall, holder,
      +[](gpointer data) {
        auto* h = static_cast<TrayHolder*>(data);
        if (h->tray) h->tray->Dispose();
        delete h;
      });
  g_object_set_data_full(G_OBJECT(view), "pagashell-tray",
                         g_object_ref(channel), g_object_unref);
  if (window) {
    g_signal_connect_data(window, "destroy", G_CALLBACK(OnWindowDestroyed),
                          new std::weak_ptr<LinuxSystemTray>(tray),
                          FreeWeakTray, static_cast<GConnectFlags>(0));
  }
}
