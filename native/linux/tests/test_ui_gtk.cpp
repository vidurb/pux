#include "test_harness.hpp"

#if defined(__linux__)

#include <gtk/gtk.h>

TEST(gtk_scrolled_window_child_can_be_replaced) {
    if (!gtk_init_check(nullptr, nullptr)) {
        SKIP_TEST("GTK display unavailable");
    }

    GtkWidget* scrolled = gtk_scrolled_window_new(nullptr, nullptr);
    GtkWidget* first = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(scrolled), first);

    GtkWidget* viewport = gtk_bin_get_child(GTK_BIN(scrolled));
    ASSERT_TRUE(viewport != nullptr);
    ASSERT_TRUE(GTK_IS_VIEWPORT(viewport));

    GtkWidget* inner = gtk_bin_get_child(GTK_BIN(viewport));
    ASSERT_TRUE(inner != nullptr);
    ASSERT_TRUE(GTK_IS_BOX(inner));
    gtk_widget_destroy(inner);

    GtkWidget* second = gtk_label_new("second view");
    gtk_container_add(GTK_CONTAINER(viewport), second);

    GtkWidget* viewport_after = gtk_bin_get_child(GTK_BIN(scrolled));
    ASSERT_TRUE(GTK_IS_VIEWPORT(viewport_after));
    GtkWidget* child = gtk_bin_get_child(GTK_BIN(viewport_after));
    ASSERT_TRUE(child != nullptr);
    ASSERT_TRUE(GTK_IS_LABEL(child));

    gtk_widget_destroy(scrolled);
}

#endif
