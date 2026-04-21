# Ghostty GTK Embedding Change Request

Smithers GTK needs to embed Ghostty's GTK4 terminal surface inside an existing
`Adw.Application`. The current Ghostty submodule does not expose a usable GTK
embedding surface for this.

## Blockers in the current submodule

- `include/ghostty.h` only exposes embedded platform tags for macOS and iOS.
  There is no GTK/Linux platform tag or API that returns a `GtkWidget *`.
- `src/apprt/embedded.zig` only supports `.macos` and `.ios` platforms. On a
  Linux build, `ghostty_surface_new` reaches `error.UnsupportedPlatform`.
- `src/renderer/OpenGL.zig` leaves the embedded OpenGL runtime as a no-op and
  notes that libghostty is strictly broken for rendering on those platforms.
- `src/apprt/gtk/class/surface.zig` is the desired `GtkWidget` subclass, but it
  is tied to `Application.default()` / `GhosttyApplication` and is compiled as
  part of the GTK executable runtime, not as an embeddable C ABI library.
- `src/build/SharedDeps.zig` only adds the GTK apprt dependencies when
  `step.kind != .lib`; `zig build -Dapp-runtime=gtk -Demit-exe=false` emits
  `libghostty-vt` but no embeddable GTK `libghostty`.

## Requested upstream shape

Please expose one of these from Ghostty:

1. Preferred: a `libghostty-gtk` embeddable artifact that compiles the GTK apprt
   as a library and exports a C ABI for creating a surface widget inside a host
   GTK application.
2. Acceptable fallback: extend the existing embedded C ABI with a GTK platform
   and make the OpenGL embedded renderer functional for a host-owned
   `GtkGLArea`.

The preferred C ABI shape would be enough for Smithers GTK:

```c
typedef void* ghostty_gtk_app_t;

GHOSTTY_API ghostty_gtk_app_t ghostty_gtk_app_new(
    GtkApplication *host_app,
    const ghostty_runtime_config_s *runtime,
    ghostty_config_t config);

GHOSTTY_API void ghostty_gtk_app_free(ghostty_gtk_app_t);
GHOSTTY_API void ghostty_gtk_app_tick(ghostty_gtk_app_t);

GHOSTTY_API ghostty_surface_t ghostty_gtk_surface_new(
    ghostty_gtk_app_t app,
    const ghostty_surface_config_s *config);

GHOSTTY_API GtkWidget *ghostty_gtk_surface_widget(ghostty_surface_t surface);
```

Implementation notes:

- The GTK surface constructor needs to avoid `Application.default()` or accept
  the owning Ghostty app/core explicitly, so it can live inside another
  `GtkApplication`.
- The library artifact should be available through Ghostty's `build.zig` so a
  downstream Zig build can depend on it through the Zig build graph.
- The widget should keep Ghostty's existing GTK handling for rendering, input,
  clipboard, IME, drag/drop, and resize.

