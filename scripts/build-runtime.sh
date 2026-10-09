#!/bin/bash
# Builds CrossOver's open-source Wine (winecx) for x86_64 (run by Rosetta) into
# build/runtime/winecx-<version>. Needs scripts/bootstrap.sh and scripts/build-deps.sh first.
#
# The result differs from a stock build in three ways:
#  - Wine's own Direct3D DLLs move to lib/wine-backends/wined3d, so the app picks a backend per
#    launch with WINEDLLPATH (Wine searches lib/wine before WINEDLLPATH).
#  - The loader's embedded Info.plist declares the games category, for macOS Game Mode.
#  - Libraries load through @rpath, so the folder can be moved anywhere.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEPS="$BUILD/deps-x86_64"
WORK="$BUILD/work-wine"
LOGS="$BUILD/logs"
RUNTIME="$BUILD/runtime/winecx-$CROSSOVER_VERSION"
SWITCHABLE_DLLS=(d3d9 d3d10 d3d10_1 d3d10core d3d11 d3d12 d3d12core dxgi nvapi64 nvngx atidxx64)

[[ -f $DEPS/.done-sdl2 ]] || { echo "Run scripts/build-deps.sh first." >&2; exit 1; }
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "Run scripts/bootstrap.sh first." >&2; exit 1; }
mkdir -p "$WORK" "$LOGS"

CX=$(crossover_sources)
WINE_SRC="$CX/wine"

log "Patching the loader's Info.plist (Game Mode, own identity)"
python3 - "$WINE_SRC/loader/wine_info.plist.in" <<'EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if "LSApplicationCategoryType" not in s:
    s = s.replace("com.codeweavers.CrossOver.wineloader", "io.github.prateek-srivastav.Corkscrew.wineloader")
    # Padding lets winecx rename the process to longer game names for the Dock.
    s = s.replace("<string>CrossOver-Hosted Application</string><!-- CrossOver Hack 10913 -->",
                  "<string>CrossOver-Hosted Application</string><!-- bundle name padding -->")
    s = s.replace("    <key>LSUIElement</key>",
                  "    <key>LSApplicationCategoryType</key>\n    <string>public.app-category.games</string>\n"
                  "    <key>LSSupportsGameMode</key>\n    <true/>\n    <key>LSUIElement</key>")
    p.write_text(s)
EOF

log "Patching the loader: optional opt-out of the Dock-name link (isolated bottles)"
# winecx re-runs itself through a link in $TMPDIR named after the game, for the Dock. The sandbox
# only lets programs inside the runtime run (allowing $TMPDIR would let malware run files it drops
# there), so isolated bottles set CORKSCREW_NO_LOADER_LINK=1 to skip the link.
python3 - "$WINE_SRC/dlls/ntdll/unix/loader.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = '    if (getenv("WINEDLLPATH"))\n        replace_wineloader_path_with_link( &(argv[1]), image_path );'
new = '    if (getenv("WINEDLLPATH") && !getenv("CORKSCREW_NO_LOADER_LINK"))\n        replace_wineloader_path_with_link( &(argv[1]), image_path );'
if new not in s:
    assert old in s, "loader.c changed upstream; update this patch"
    p.write_text(s.replace(old, new))
PATCH

log "Patching kernelbase: Social Club's Chromium draws in its own process"
# Chromium draws a window's contents from its GPU process, but the window belongs to the browser
# process, and winemac only shows what a window's own process draws (GDI, OpenGL and Vulkan alike).
# Rockstar's SocialClubHelper.exe (the Rockstar Games Launcher's pages and prompts) then stays
# white. --in-process-gpu moves that work into the browser process; SwiftShader, because Chromium's
# Direct3D 11 path crashes under Wine and would now take the browser down with it.
# (Steam's web helper has the same problem; tools/steamwebhelper-wrapper handles it.)
python3 - "$WINE_SRC/dlls/kernelbase/process.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = '''    /* Warn if unsupported features are used */

    if (flags & (IDLE_PRIORITY_CLASS'''
new = '''    /* Corkscrew: Rockstar's Social Club draws from Chromium's GPU process into windows of its
     * browser process, which winemac can't show; do that work in the browser process. */
    {
        static const WCHAR social_club_flagsW[] = L" --in-process-gpu --use-gl=angle --use-angle=swiftshader";
        const WCHAR *exe = wcsrchr( app_name, '\\\\' ) ? wcsrchr( app_name, '\\\\' ) + 1 : app_name;

        if (!wcsicmp( exe, L"SocialClubHelper.exe" ) && !wcsstr( tidy_cmdline, L"--type=" ))
        {
            SIZE_T len = lstrlenW( tidy_cmdline ) + ARRAY_SIZE(social_club_flagsW);
            WCHAR *new_cmdline = RtlAllocateHeap( GetProcessHeap(), 0, len * sizeof(WCHAR) );

            if (new_cmdline)
            {
                lstrcpyW( new_cmdline, tidy_cmdline );
                lstrcatW( new_cmdline, social_club_flagsW );
                if (tidy_cmdline != cmd_line) HeapFree( GetProcessHeap(), 0, tidy_cmdline );
                tidy_cmdline = new_cmdline;
                WARN( "Social Club browser process: %s\\n", debugstr_w(tidy_cmdline) );
            }
        }
    }

''' + anchor
if new not in s:
    assert s.count(anchor) == 1, "process.c changed upstream; update this patch"
    p.write_text(s.replace(anchor, new))
PATCH

log "Staging MoltenVK $MOLTENVK_VERSION"
if [[ ! -f $DEPS/lib/libMoltenVK.dylib ]]; then
  tarball=$(fetch "$MOLTENVK_URL" "$MOLTENVK_SHA256")
  tmp=$(mktemp -d)
  tar -xf "$tarball" -C "$tmp" MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
  lipo "$tmp/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" -thin x86_64 -output "$DEPS/lib/libMoltenVK.dylib"
  install_name_tool -id @rpath/libMoltenVK.dylib "$DEPS/lib/libMoltenVK.dylib"
  rm -rf "$tmp"
fi

log "Making the x86_64 libraries relocatable (@rpath)"
# Must happen before configure: Wine records each library's install name as the name it dlopens.
for lib in "$DEPS"/lib/*.dylib; do
  [[ -L $lib ]] && continue
  name=$(basename "$lib")
  install_name_tool -id "@rpath/$name" "$lib" 2>/dev/null
  otool -L "$lib" | awk 'NR>1 {print $1}' | { grep -F "$DEPS/lib/" || true; } | while read -r dep; do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib" 2>/dev/null
  done
  otool -l "$lib" | grep -q "path @loader_path " || install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null
  codesign --force --sign - "$lib" 2>/dev/null
done

log "Configuring Wine $CROSSOVER_VERSION (log: $LOGS/wine-configure.log)"
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$(brew --prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC="clang -arch x86_64" CXX="clang++ -arch x86_64"
export x86_64_CC=x86_64-w64-mingw32-gcc i386_CC=i686-w64-mingw32-gcc   # gcc, not llvm-mingw
export CPPFLAGS="-I$DEPS/include" CFLAGS="-O2 -Wno-error=implicit-function-declaration"
export LDFLAGS="-L$DEPS/lib -Wl,-rpath,@loader_path -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" PKG_CONFIG_PATH=""
unset CPATH LIBRARY_PATH C_INCLUDE_PATH
CONFIGURE_ARGS=(
  --build=x86_64-apple-darwin --host=x86_64-apple-darwin --prefix=/
  --enable-archs=i386,x86_64 --disable-tests
  --with-gnutls --with-freetype --with-sdl --with-vulkan
  --without-x --without-wayland --without-gstreamer --without-ffmpeg --without-cups --without-sane
  --without-usb --without-v4l2 --without-pcap --without-capi --without-krb5 --without-netapi
  --without-inotify --without-dbus --without-oss --without-alsa --without-pulse
  ac_cv_lib_soname_MoltenVK=libMoltenVK.dylib
  # configure links against the build Mac's SDK and finds functions newer than
  # MACOSX_DEPLOYMENT_TARGET. They become weak imports that are NULL on older macOS, and calling one
  # crashes (SIGSEGV). pipe2 is macOS 27+; ntdll calls it at startup.
  ac_cv_func_pipe2=no
)
# Reconfigure when the arguments change; a stale Makefile would keep the old results.
if [[ ! -f $WORK/Makefile || "$(cat "$WORK/.configure-args" 2>/dev/null)" != "${CONFIGURE_ARGS[*]}" ]]; then
  rm -f "$WORK/Makefile" "$WORK/config.cache"
  (cd "$WORK" && "$WINE_SRC/configure" "${CONFIGURE_ARGS[@]}") >"$LOGS/wine-configure.log" 2>&1 \
    || { tail -40 "$LOGS/wine-configure.log" >&2; rm -f "$WORK/Makefile"; exit 1; }
  echo "${CONFIGURE_ARGS[*]}" >"$WORK/.configure-args"
fi
grep -E "^configure: (WARNING|error)|SONAME_LIB(GNUTLS|FREETYPE|SDL2|MOLTENVK|VULKAN)" \
  "$LOGS/wine-configure.log" "$WORK/include/config.h" 2>/dev/null || true

# sfnt2fon (builds Wine's bitmap fonts) finds FreeType via @loader_path, i.e. its own folder.
mkdir -p "$WORK/tools/sfnt2fon"
ln -sf "$DEPS/lib/libfreetype.6.dylib" "$WORK/tools/sfnt2fon/libfreetype.6.dylib"
log "Building Wine with $JOBS jobs (log: $LOGS/wine-build.log)"
make -C "$WORK" -j"$JOBS" >"$LOGS/wine-build.log" 2>&1 || { tail -40 "$LOGS/wine-build.log" >&2; exit 1; }

log "Installing into $RUNTIME"
rm -rf "$RUNTIME"
make -C "$WORK" install-lib DESTDIR="$RUNTIME" >"$LOGS/wine-install.log" 2>&1 || { tail -40 "$LOGS/wine-install.log" >&2; exit 1; }

log "Bundling x86_64 libraries"
for lib in "$DEPS"/lib/*.dylib; do
  cp -a "$lib" "$RUNTIME/lib/"                                      # keeps version symlinks
  [[ -L $lib ]] || ln -sf "../../$(basename "$lib")" "$RUNTIME/lib/wine/x86_64-unix/$(basename "$lib")"
done

log "Moving Wine's Direct3D DLLs to lib/wine-backends/wined3d"
for arch in x86_64-windows i386-windows x86_64-unix; do
  mkdir -p "$RUNTIME/lib/wine-backends/wined3d/$arch"
  for dll in "${SWITCHABLE_DLLS[@]}"; do
    for f in "$RUNTIME/lib/wine/$arch/$dll".{dll,so}; do
      [[ -e $f ]] && mv "$f" "$RUNTIME/lib/wine-backends/wined3d/$arch/"
    done
  done
done

log "Checking that nothing points back into the build folder"
leaks=$(find "$RUNTIME" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -exec sh -c \
  'otool -L "$1" 2>/dev/null | tail -n +2 | grep -F "'"$BUILD"'" >/dev/null && echo "$1"' _ {} \; || true)
[[ -z $leaks ]] || { echo "Absolute build paths remain in:" >&2; echo "$leaks" >&2; exit 1; }

log "Checking for system functions newer than macOS $MACOSX_DEPLOYMENT_TARGET"
# A weak import from libSystem is a function the build SDK has but the deployment target may not;
# on an older macOS it is NULL and calling it crashes. These ones exist on every supported macOS
# (or the caller checks for NULL); anything else must be turned off in CONFIGURE_ARGS.
KNOWN_WEAK=(___ulock_wait2 __availability_version_check _dispatch_once_f)
weak=$(find "$RUNTIME" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) ! -name '*.dll' ! -name '*.exe' \
  -exec sh -c 'file "$1" | grep -q Mach-O && nm -m "$1" 2>/dev/null \
    | awk -v f="$1" '"'"'/\(undefined\) weak external .* \(from libSystem\)/ {print f": "$4}'"'"'' _ {} \; \
  | grep -vwF "$(printf '%s\n' "${KNOWN_WEAK[@]}")" || true)
[[ -z $weak ]] || { echo "Functions that may be missing on macOS $MACOSX_DEPLOYMENT_TARGET:" >&2; echo "$weak" >&2; exit 1; }

cat >"$RUNTIME/manifest.json" <<EOF
{
  "id": "winecx-$CROSSOVER_VERSION-x86_64",
  "architecture": "x86_64",
  "source": "$CROSSOVER_URL",
  "sourceSHA256": "$CROSSOVER_SHA256",
  "moltenVK": "$MOLTENVK_VERSION",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
log "Runtime ready: $RUNTIME ($(du -sh "$RUNTIME" | cut -f1))"
[[ -d $BUILD/components/dxmt-$DXMT_VERSION ]] \
  && echo "Run scripts/install-components.sh again: it puts DXMT's winemetal back into the rebuilt runtime."
"$RUNTIME/bin/wine" --version
