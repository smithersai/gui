# Smithers GTK

GTK4/libadwaita Linux shell for SmithersGUI, written in Zig and consuming the
`libsmithers/include/smithers.h` ABI.

## Dependencies

Debian/Ubuntu:

```sh
sudo apt update
sudo apt install zig pkg-config libgtk-4-dev libadwaita-1-dev xvfb
```

Arch:

```sh
sudo pacman -S zig pkgconf gtk4 libadwaita xorg-server-xvfb
```

Nix:

```sh
nix shell nixpkgs#zig_0_15 nixpkgs#pkg-config nixpkgs#gtk4 nixpkgs#libadwaita nixpkgs#xvfb-run
```

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
