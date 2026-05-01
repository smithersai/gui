# Smithers GTK

GTK4/libadwaita Linux shell for SmithersGUI, written in Zig and consuming the
`libsmithers/include/smithers.h` ABI.

## Dependencies

Debian/Ubuntu:

```sh
sudo apt update
sudo apt install zig pkg-config libgtk-4-dev libadwaita-1-dev \
  libglib2.0-dev libgdk-pixbuf-2.0-dev libpango1.0-dev \
  bun blueprint-compiler libfontconfig-dev libfreetype-dev libharfbuzz-dev libpng-dev \
  libonig-dev libwayland-dev libx11-dev xvfb
```

Arch:

```sh
sudo pacman -S zig bun blueprint-compiler pkgconf gtk4 libadwaita glib2 gdk-pixbuf2 pango \
  fontconfig freetype2 harfbuzz libpng oniguruma wayland libx11 \
  xorg-server-xvfb
```

Nix:

```sh
nix shell nixpkgs#zig_0_15 nixpkgs#bun nixpkgs#blueprint-compiler nixpkgs#pkg-config nixpkgs#gtk4 \
  nixpkgs#libadwaita nixpkgs#glib nixpkgs#gdk-pixbuf nixpkgs#pango \
  nixpkgs#fontconfig nixpkgs#freetype nixpkgs#harfbuzz nixpkgs#libpng \
  nixpkgs#oniguruma nixpkgs#wayland nixpkgs#xorg.libX11 nixpkgs#xvfb-run
```

The terminal backend embeds Ghostty's GTK apprt as a real `GtkWidget`. Smithers
keeps the Ghostty submodule pinned and stores downstream integration changes in
`linux/patches/`; the submodule itself should not be edited directly.

`zig build` runs `bun linux/scripts/apply-ghostty-patches.ts` before compiling
`smithers-gtk`. The script is idempotent: it applies unapplied patches and
skips patches that are already present. You can run it manually from the repo
root:

```sh
bun linux/scripts/apply-ghostty-patches.ts
```

The build then asks Ghostty to emit `libghostty-gtk` with:

```sh
cd ghostty
zig build -Dapp-runtime=gtk -Demit-exe=false
```

Smithers links that library from `ghostty/zig-out/lib` and uses the exported
GTK embed ABI from `linux/src/features/ghostty.zig`.

## Build

```sh
cd /Users/williamcory/gui/linux
zig build
```

Until `../libsmithers/zig-out/lib/libsmithers.a` exists, the build defaults to
`-Dstub-libsmithers=true` and links `linux/stub/libsmithers_stub.zig`. Force a
real libsmithers link with:

```sh
zig build -Dstub-libsmithers=false
```

## Run

```sh
zig build run
```

Smoke mode opens the app, optionally opens the command palette, then exits:

```sh
zig-out/bin/smithers-gtk --smoke --show-palette
```

## Tests

```sh
zig build test
./test/smoke.sh
```

The shell script uses `xvfb-run` when available; otherwise it prints the manual
command for a graphical session.
