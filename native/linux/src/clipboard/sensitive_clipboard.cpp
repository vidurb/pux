#include "sensitive_clipboard.hpp"
#include <gtk/gtk.h>
#include <glib.h>

namespace pux {
namespace clipboard {

namespace {

void default_gtk_set_clipboard(const std::string& text) {
    GdkDisplay* display = gdk_display_get_default();
    if (!display) return;
    GtkClipboard* clip = gtk_clipboard_get_default(display);
    if (clip) {
        gtk_clipboard_set_text(clip, text.c_str(), static_cast<gint>(text.size()));
    }
}

std::string default_gtk_get_clipboard() {
    GdkDisplay* display = gdk_display_get_default();
    if (!display) return "";
    GtkClipboard* clip = gtk_clipboard_get_default(display);
    if (clip) {
        gchar* text = gtk_clipboard_wait_for_text(clip);
        if (text) {
            std::string result(text);
            g_free(text);
            return result;
        }
    }
    return "";
}

gboolean timer_callback(gpointer user_data) {
    auto* self = static_cast<SensitiveClipboard*>(user_data);
    self->clear_if_unchanged();
    return G_SOURCE_REMOVE;
}

} // namespace

SensitiveClipboard::SensitiveClipboard(ClipboardSetter setter, ClipboardGetter getter)
    : setter_(setter ? std::move(setter) : default_gtk_set_clipboard),
      getter_(getter ? std::move(getter) : default_gtk_get_clipboard) {}

SensitiveClipboard::~SensitiveClipboard() {
    cancel();
}

SensitiveClipboard& SensitiveClipboard::instance() {
    static SensitiveClipboard inst;
    return inst;
}

void SensitiveClipboard::cancel() {
    if (timer_id_ != 0) {
        g_source_remove(timer_id_);
        timer_id_ = 0;
    }
}

void SensitiveClipboard::copy(const std::string& text) {
    cancel();
    last_copied_ = text;
    if (setter_) {
        setter_(text);
    }
    // Schedule clearing after 60 seconds
    timer_id_ = g_timeout_add_seconds(
        static_cast<guint>(kClearAfter.count()),
        timer_callback,
        this
    );
}

void SensitiveClipboard::clear_if_unchanged() {
    timer_id_ = 0;
    if (!last_copied_.empty() && getter_) {
        std::string current = getter_();
        if (current == last_copied_) {
            if (setter_) {
                setter_("");
            }
        }
    }
    last_copied_.clear();
}

} // namespace clipboard
} // namespace pux
