/* rcc-shot: render the app's real CSS + real widget classes to a PNG.
   Mirrors the structure RcWindow builds (custom ListBox rail, Adw.Clamp
   content column, AdwPreferencesGroup rows) so the styling can be seen
   without a screenshot tool. */
#include <gtk/gtk.h>
#include <adwaita.h>
#include <gdk/gdk.h>

static GtkWidget *root, *pagebox;
static void dump_labels(GtkWidget *w) {
  if (GTK_IS_LABEL(w)) {
    graphene_rect_t a;
    if (!gtk_widget_compute_bounds(w, pagebox, &a)) return;
    const char *t = gtk_label_get_text(GTK_LABEL(w));
    if (t && *t)
      g_print("  label y=%.0f h=%.0f '%s'\n", a.origin.y, a.size.height, t);
  }
  for (GtkWidget *c = gtk_widget_get_first_child(w); c;
       c = gtk_widget_get_next_sibling(c))
    dump_labels(c);
}

static void collect_lists(GtkWidget *w, GList **out) {
  if (GTK_IS_LIST_BOX(w)) *out = g_list_prepend(*out, w);
  for (GtkWidget *c = gtk_widget_get_first_child(w); c;
       c = gtk_widget_get_next_sibling(c))
    collect_lists(c, out);
}

static GtkWidget *lab(const char *cls, const char *txt) {
  GtkWidget *l = gtk_label_new(txt);
  if (cls) gtk_widget_add_css_class(l, cls);
  gtk_label_set_xalign(GTK_LABEL(l), 0.0f);
  return l;
}

static GtkWidget *nav_row(const char *icon, const char *name,
                          const char *val, gboolean on) {
  GtkWidget *row = gtk_list_box_row_new();
  gtk_widget_set_size_request(row, -1, 38);
  gtk_widget_add_css_class(row, "nav-row");
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  gtk_widget_set_margin_start(box, 11);
  gtk_widget_set_margin_end(box, 11);
  gtk_widget_set_margin_top(box, 9);
  gtk_widget_set_margin_bottom(box, 9);
  GtkWidget *im = gtk_image_new_from_icon_name(icon);
  gtk_widget_add_css_class(im, "nav-icon");
  GtkWidget *l = lab("nav-label", name);
  gtk_widget_set_hexpand(l, TRUE);
  GtkWidget *v = lab("nav-value", val);
  gtk_widget_add_css_class(v, "nav-value");
  gtk_box_append(GTK_BOX(box), im);
  gtk_box_append(GTK_BOX(box), l);
  gtk_box_append(GTK_BOX(box), v);
  gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
  return row;
}

static void add_group(GtkWidget *page, const char *title,
                      const char *desc, const char *r1t, const char *r1s,
                      const char *r2t, const char *r2s) {
  GtkWidget *g = GTK_WIDGET(adw_preferences_group_new());
  adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(g), title);
  if (desc) adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(g), desc);
  GtkWidget *a = adw_action_row_new();
  adw_preferences_row_set_title(ADW_PREFERENCES_ROW(a), r1t);
  if (r1s) adw_action_row_set_subtitle(ADW_ACTION_ROW(a), r1s);
  GtkWidget *sw = gtk_switch_new();
  gtk_widget_set_valign(sw, GTK_ALIGN_CENTER);
  gtk_switch_set_active(GTK_SWITCH(sw), TRUE);
  adw_action_row_add_suffix(ADW_ACTION_ROW(a), sw);
  adw_preferences_group_add(ADW_PREFERENCES_GROUP(g), a);
  GtkWidget *b = adw_action_row_new();
  adw_preferences_row_set_title(ADW_PREFERENCES_ROW(b), r2t);
  if (r2s) adw_action_row_set_subtitle(ADW_ACTION_ROW(b), r2s);
  GtkWidget *vl = gtk_label_new("78%");
  gtk_widget_set_valign(vl, GTK_ALIGN_CENTER);
  adw_action_row_add_suffix(ADW_ACTION_ROW(b), vl);
  adw_preferences_group_add(ADW_PREFERENCES_GROUP(g), b);
  gtk_box_append(GTK_BOX(page), g);
}

int main(int argc, char **argv) {
  const char *cssfile = argc > 1 ? argv[1] : "/tmp/app.css";
  const char *out = argc > 2 ? argv[2] : "/tmp/page.png";
  int W = argc > 3 ? atoi(argv[3]) : 1180;
  int H = argc > 4 ? atoi(argv[4]) : 900;

  adw_init();
  GtkCssProvider *p = gtk_css_provider_new();
  gtk_css_provider_load_from_path(p, cssfile);
  g_print("css loaded\n");
  gtk_style_context_add_provider_for_display(
      gdk_display_get_default(), GTK_STYLE_PROVIDER(p),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

  root = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  GtkWidget *rootw = root; (void)rootw;
  adw_style_manager_set_color_scheme(adw_style_manager_get_default(),
                                      ADW_COLOR_SCHEME_FORCE_DARK);

  /* rail */
  GtkWidget *rail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_add_css_class(rail, "rcc-rail");
  gtk_widget_set_size_request(rail, 210, -1);
  GtkWidget *brand = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
  gtk_widget_add_css_class(brand, "rail-brand");
  gtk_box_append(GTK_BOX(brand), lab("rail-brand-title", "Razer Blade 16"));
  gtk_box_append(GTK_BOX(brand), lab("rail-brand-sub", "2024 · openrazer"));
  gtk_box_append(GTK_BOX(rail), brand);
  gtk_box_append(GTK_BOX(rail), lab("nav-heading", "DEVICE"));
  GtkWidget *list = gtk_list_box_new();
  gtk_list_box_set_selection_mode(GTK_LIST_BOX(list),
                                  GTK_SELECTION_SINGLE);
  gtk_widget_add_css_class(list, "rcc-nav");
  gtk_widget_set_vexpand(list, TRUE);
  gtk_list_box_append(GTK_LIST_BOX(list), nav_row("keyboard-brightness-symbolic",
                                        "Lighting", "", TRUE));
  gtk_list_box_append(GTK_LIST_BOX(list), nav_row("video-display-symbolic",
                                        "Display", "64%", FALSE));
  gtk_list_box_append(GTK_LIST_BOX(list), nav_row("battery-full-charging-symbolic",
                                        "Power", "84%", FALSE));
  gtk_list_box_append(GTK_LIST_BOX(list), nav_row("video-display-symbolic", "GPU",
                                        "awake", FALSE));
  gtk_list_box_append(GTK_LIST_BOX(list), nav_row("emblem-system-symbolic",
                                        "Diagnostics", "RUNNING", FALSE));
  gtk_box_append(GTK_BOX(rail), list);
  GtkWidget *stats = gtk_label_new("CPU  52 °C\nBATTERY  84%\nFAN  auto\nMODE  Default");
  gtk_label_set_markup(GTK_LABEL(stats),
      "CPU  <span foreground='#e8eaed'>52 °C</span>\n"
      "BATTERY  <span foreground='#e8eaed'>84%</span>\n"
      "FAN  <span foreground='#e8eaed'>auto</span>\n"
      "MODE  <span foreground='#e8eaed'>Default</span>");
  gtk_label_set_xalign(GTK_LABEL(stats), 0.0f);
  gtk_widget_add_css_class(stats, "rail-stats");
  gtk_box_append(GTK_BOX(rail), stats);
  gtk_box_append(GTK_BOX(root), rail);

  /* content */
  GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 24);
  pagebox = page;
  gtk_widget_set_margin_start(page, 30);
  gtk_widget_set_margin_end(page, 30);
  gtk_widget_set_margin_top(page, 20);
  AdwClamp *clamp = ADW_CLAMP(adw_clamp_new());
  adw_clamp_set_maximum_size(clamp, 820);
  adw_clamp_set_tightening_threshold(clamp, 560);
  adw_clamp_set_child(clamp, page);
  gtk_box_append(GTK_BOX(root), GTK_WIDGET(clamp));
  gtk_list_box_select_row(GTK_LIST_BOX(list),
                          gtk_list_box_get_row_at_index(GTK_LIST_BOX(list), 0));

  add_group(page, "Brightness &amp; effects", NULL, "Keyboard brightness",
            "Direct frame, main zone", "Screen brightness",
            "Backlight, 5 minute cap");
  add_group(page, "Daemon", NULL, "Chroma daemon",
            "openrazer-daemon, auto-started", "Re-apply profile at login",
            "Custom key frames are volatile");
  add_group(page, "Fan", "Thermal management for the Blade 16 (2024)",
            "Fan control", "TFN1 · thermal zone", "Fan level", "1 - 50");

  /* Lay the tree out in a real mapped window, then snapshot the child.
     The window is made fully transparent so nothing appears on screen, but
     it still allocates the widget so the CSS actually resolves. */
  GtkWidget *win = gtk_window_new();
  gtk_window_set_decorated(GTK_WINDOW(win), FALSE);
  gtk_window_set_default_size(GTK_WINDOW(win), W, H);
  gtk_window_set_resizable(GTK_WINDOW(win), FALSE);
  gtk_window_set_application(GTK_WINDOW(win),
      gtk_window_get_application(GTK_WINDOW(root)));
  gtk_window_set_child(GTK_WINDOW(win), root);
  gtk_widget_set_opacity(win, 0.0);
  gtk_window_present(GTK_WINDOW(win));
  for (int i = 0; i < 400 && !gtk_widget_get_mapped(win); i++)
    g_main_context_iteration(NULL, FALSE);
  for (int i = 0; i < 40; i++)
    g_main_context_iteration(NULL, FALSE);

  /* debug: report the real allocation of every list row */
  {
    GList *lboxes = NULL;
    collect_lists(page, &lboxes);
    for (GList *li = lboxes; li; li = li->next) {
      GtkWidget *r = gtk_widget_get_first_child(GTK_WIDGET(li->data));
      while (r) {
        { graphene_rect_t a;
          if (gtk_widget_compute_bounds(r, pagebox, &a))
            g_print("row y=%.0f h=%.0f\n", a.origin.y, a.size.height); }
        r = gtk_widget_get_next_sibling(r);
      }
    }
    g_list_free(lboxes);
    g_print("--- labels ---\n");
    dump_labels(page);
  }
  GtkSnapshot *snap = gtk_snapshot_new();
  gtk_widget_snapshot_child(win, root, snap);
  GskRenderNode *node = gtk_snapshot_free_to_node(snap);
  g_print("node=%p\n", (void *)node);
  if (!node) return 1;

  GdkSurface *gs = gtk_native_get_surface(GTK_NATIVE(win));
  GskRenderer *r = gsk_renderer_new_for_surface(gs);
  graphene_rect_t vp;
  graphene_rect_init(&vp, 0, 0, (float)W, (float)H);
  GdkTexture *tex = gsk_renderer_render_texture(r, node, &vp);
  if (!tex) { g_printerr("no texture\n"); return 1; }
  g_print("texture %ux%u\n", gdk_texture_get_width(tex),
          gdk_texture_get_height(tex));
  gdk_texture_save_to_png(tex, out);
  g_print("wrote %s\n", out);
  return 0;
}
