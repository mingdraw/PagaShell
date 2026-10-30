#ifndef PAGASHELL_CLIPBOARD_H_
#define PAGASHELL_CLIPBOARD_H_
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
constexpr size_t kClipboardLimit = 16 * 1024 * 1024;
struct ClipboardState {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  uint64_t generation = 1;
  gulong signal = 0;
  ClipboardState() {
    g_object_ref(clipboard);
    signal = g_signal_connect(clipboard, "owner-change", G_CALLBACK(
        +[](GtkClipboard*, GdkEventOwnerChange*, gpointer data) {
          ++static_cast<ClipboardState*>(data)->generation;
        }), this);
  }
  ~ClipboardState() {
    g_signal_handler_disconnect(clipboard, signal);
    g_object_unref(clipboard);
  }
};

void ClipboardError(FlMethodCall* call, const char* code) {
  fl_method_call_respond_error(call, code, "Clipboard operation failed", nullptr, nullptr);
}

struct ClipboardRead {
  FlMethodCall* call;
  std::shared_ptr<ClipboardState> state;
  uint64_t generation;
  int retries = 0;
  std::vector<std::string> files;
  explicit ClipboardRead(FlMethodCall* method, std::shared_ptr<ClipboardState> clipboard)
      : call(FL_METHOD_CALL(g_object_ref(method))), state(std::move(clipboard)),
        generation(state->generation) {}
  ~ClipboardRead() { g_object_unref(call); }
};

void ReadUris(GtkClipboard*, gchar**, gpointer);

void FinishRead(ClipboardRead* read, const gchar* text) {
  if (read->generation != read->state->generation) {
    if (++read->retries <= 2) {
      read->generation = read->state->generation;
      read->files.clear();
      gtk_clipboard_request_uris(read->state->clipboard, ReadUris, read);
    } else {
      ClipboardError(read->call, "clipboard_busy");
      delete read;
    }
    return;
  }
  if (text && std::strlen(text) > kClipboardLimit) {
    ClipboardError(read->call, "clipboard_limit");
    delete read;
    return;
  }
  g_autoptr(FlValue) value = fl_value_new_map();
  fl_value_set_string_take(value, "changeId",
      fl_value_new_string(std::to_string(read->generation).c_str()));
  fl_value_set_string_take(value, "text",
      text ? fl_value_new_string(text) : fl_value_new_null());
  FlValue* files = fl_value_new_list();
  for (const auto& path : read->files) {
    fl_value_append_take(files, fl_value_new_string(path.c_str()));
  }
  fl_value_set_string_take(value, "files", files);
  fl_method_call_respond_success(read->call, value, nullptr);
  delete read;
}

void ReadUris(GtkClipboard* clipboard, gchar** uris, gpointer data) {
  auto* read = static_cast<ClipboardRead*>(data);
  if (uris) {
    for (size_t i = 0; uris[i]; i++) {
      if (i >= 4096) {
        ClipboardError(read->call, "clipboard_limit");
        delete read;
        return;
      }
      g_autofree gchar* host = nullptr;
      g_autofree gchar* path = g_filename_from_uri(uris[i], &host, nullptr);
      if (path && (!host || !*host || g_strcmp0(host, "localhost") == 0)) {
        read->files.emplace_back(path);
      }
    }
  }
  if (!read->files.empty()) {
    FinishRead(read, nullptr);
  } else {
    gtk_clipboard_request_text(clipboard, +[](GtkClipboard*, const gchar* text, gpointer data) {
      FinishRead(static_cast<ClipboardRead*>(data), text);
    }, read);
  }
}

struct ClipboardFiles {
  std::vector<std::string> uris;
  std::string gnome = "copy\n";
};

void ClipboardCall(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto state = *static_cast<std::shared_ptr<ClipboardState>*>(data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    ClipboardError(call, "clipboard_invalid");
    return;
  }
  if (g_strcmp0(method, "read") == 0) {
    FlValue* after = fl_value_lookup_string(args, "afterChangeId");
    if (after && fl_value_get_type(after) == FL_VALUE_TYPE_STRING &&
        std::to_string(state->generation) == fl_value_get_string(after)) {
      fl_method_call_respond_success(call, nullptr, nullptr);
    } else {
      auto* read = new ClipboardRead(call, state);
      gtk_clipboard_request_uris(state->clipboard, ReadUris, read);
    }
    return;
  }
  if (g_strcmp0(method, "write") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* expected = fl_value_lookup_string(args, "expectedChangeId");
  if (!expected || fl_value_get_type(expected) != FL_VALUE_TYPE_STRING ||
      std::to_string(state->generation) != fl_value_get_string(expected)) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  FlValue* paths = fl_value_lookup_string(args, "files");
  if (paths && fl_value_get_type(paths) == FL_VALUE_TYPE_LIST && fl_value_get_length(paths) > 0) {
    if (fl_value_get_length(paths) > 4096) { ClipboardError(call, "clipboard_limit"); return; }
    auto files = std::make_unique<ClipboardFiles>();
    for (size_t i = 0; i < fl_value_get_length(paths); i++) {
      FlValue* item = fl_value_get_list_value(paths, i);
      if (fl_value_get_type(item) != FL_VALUE_TYPE_STRING ||
          !g_path_is_absolute(fl_value_get_string(item))) {
        ClipboardError(call, "clipboard_invalid");
        return;
      }
      g_autofree gchar* uri = g_filename_to_uri(fl_value_get_string(item), nullptr, nullptr);
      if (!uri) { ClipboardError(call, "clipboard_invalid"); return; }
      files->uris.emplace_back(uri);
      files->gnome += std::string(uri) + "\n";
      if (files->gnome.size() > kClipboardLimit) { ClipboardError(call, "clipboard_limit"); return; }
    }
    GtkTargetEntry targets[] = {
      {const_cast<gchar*>("text/uri-list"), 0, 0},
      {const_cast<gchar*>("x-special/gnome-copied-files"), 0, 1},
    };
    const gboolean ok = gtk_clipboard_set_with_data(state->clipboard, targets, 2,
        +[](GtkClipboard*, GtkSelectionData* selection, guint info, gpointer data) {
          auto* files = static_cast<ClipboardFiles*>(data);
          if (info == 0) {
            std::vector<gchar*> uris;
            for (auto& uri : files->uris) uris.push_back(const_cast<gchar*>(uri.c_str()));
            uris.push_back(nullptr);
            gtk_selection_data_set_uris(selection, uris.data());
          } else {
            gtk_selection_data_set(selection, gtk_selection_data_get_target(selection), 8,
                reinterpret_cast<const guchar*>(files->gnome.data()),
                static_cast<gint>(files->gnome.size()));
          }
        },
        +[](GtkClipboard*, gpointer data) { delete static_cast<ClipboardFiles*>(data); },
        files.get());
    if (!ok) { ClipboardError(call, "clipboard_write"); return; }
    files.release();
    gtk_clipboard_set_can_store(state->clipboard, nullptr, 0);
  } else {
    FlValue* value = fl_value_lookup_string(args, "text");
    if (value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
      const gchar* text = fl_value_get_string(value);
      if (std::strlen(text) > kClipboardLimit) { ClipboardError(call, "clipboard_limit"); return; }
      gtk_clipboard_set_text(state->clipboard, text, -1);
    } else {
      gtk_clipboard_clear(state->clipboard);
    }
  }
  ++state->generation;
  g_autoptr(FlValue) change = fl_value_new_string(std::to_string(state->generation).c_str());
  fl_method_call_respond_success(call, change, nullptr);
}

void RegisterClipboard(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "pagashell/clipboard",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, ClipboardCall,
      new std::shared_ptr<ClipboardState>(std::make_shared<ClipboardState>()),
      +[](gpointer data) { delete static_cast<std::shared_ptr<ClipboardState>*>(data); });
  g_object_set_data_full(G_OBJECT(view), "pagashell-clipboard", g_object_ref(channel), g_object_unref);
}
}  // namespace
#endif  // PAGASHELL_CLIPBOARD_H_
