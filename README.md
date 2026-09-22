# xrootclock

A minimal X11 root-window clock. It writes a `strftime(3)`-formatted string into the root window's `WM_NAME` property on
a wall-clock-aligned interval — the property `dwm`, `dwmblocks` and `xsetroot -name` use for the status bar.

It speaks the X11 wire protocol directly over the display's Unix socket, so it links against nothing but libc and builds
as a 63 KB static musl binary. After startup each update costs three syscalls: `write`, `recvfrom`, `clock_nanosleep`.
Reading the clock costs none — the vDSO handles it — and musl maps `/etc/localtime` once, so there is no per-tick
timezone I/O.

---

## Should you use this?

Probably not — use [slstatus](https://tools.suckless.org/slstatus/). It is packaged nearly everywhere, it is smaller
(29 KB installed against this program's 63 KB), its shipped default configuration is a clock and nothing else, and it
holds one X connection open for the life of the process just as this does. It also does battery, volume and network,
which this does not. There is no performance argument for picking xrootclock over it.

This exists because I wanted to see what the X11 protocol looks like underneath libX11, and it turned into something
usable. Two things it does that slstatus does not: set the property once and exit (`-1`, a drop-in for
`xsetroot -name`), and take a `strftime` format as an argument rather than requiring a recompile.

It does compare well against the thing people actually write instead — an `xsetroot -name "$(date …)"` shell loop spends
~150 syscalls and ~4 ms per tick, forking two processes and opening a fresh authenticated X connection every time.

Only one instance can drive the bar: `WM_NAME` is a single string, so a second one would fight the first. That is true
of slstatus and `xsetroot` too — it is how the property works, not a limitation of this program — but it does mean this
cannot be one field among several.

---

## Requirements

**clang and musl. Both are enforced by `build.sh`, not merely recommended.**

This is the only tested configuration, and everything documented here is musl's — the binary sizes, the syscall counts,
the `strftime` behaviour `-u` exists to work around, and two tests that pin musl's rejection of the GNU `%^` modifier. A
build against another libc runs, but is not the program described here, and its suite fails for reasons that are not
bugs. So the script refuses:

```
$ CC=/usr/bin/clang ./build.sh
./build.sh: /usr/bin/clang targets glibc, not musl.
```

gcc cannot be used at all: the build gate is `-Weverything`, a clang extension with no GCC equivalent. Verified clean on
clang 21.1.7 and 22.1.4.

### Getting a musl toolchain

`build.sh` defaults to `$HOME/bin/musl-clang` and honours `$CC`:

```sh
CC=/path/to/musl-clang ./build.sh
```

| Route | Notes |
|---|---|
| musl-native distro (Alpine, void-musl) | plain `clang` already targets musl — no wrapper |
| Build musl from source | `./configure --prefix=$HOME/musl CC=clang && make && make install` — `musl-clang` is musl's own wrapper and lands in `<prefix>/bin`. ~3.5 MB. |
| Packaged cross toolchain | e.g. `cross-x86_64-linux-musl` on Void |
| `zig cc -target x86_64-linux-musl` | one binary, ships its own musl |

There is no `musl-clang` package on a glibc distro — it is generated when you build musl, which is why the default path
points into `$HOME`.

---

## Quick Start

```sh
./build.sh
./bin/release/xrootclock &
```

Typically launched from `~/.xinitrc` before the window manager:

```sh
xrootclock -u &
exec dwm
```

---

## Usage

```
xrootclock [-i SECONDS] [-1] [-u] [FORMAT]
```

| Option | Default | Description |
|---|---|---|
| `-i`, `--interval` | `60` | Update interval in seconds, aligned to the wall clock (1–86400) |
| `-1`, `--once` | off | Update once and exit — a drop-in for `xsetroot -name` |
| `-u`, `--upper` | off | Upper-case the ASCII letters in the result |
| `-h`, `--help` | — | Show usage |

`FORMAT` is any `strftime(3)` format string, defaulting to `" %a %m%d%y %I%M "` — the spaces on both sides pad it away
from the bar edges.

```sh
xrootclock                           # " Wed 091626 1222 ", on each minute boundary
xrootclock -u                        # " WED 091626 1222 "
xrootclock -i 1 '%H:%M:%S'           # seconds resolution
xrootclock -i 30 ' %a %Y-%m-%d %H:%M '
xrootclock -1 'maintenance mode'     # set once and exit
xrootclock -1 -- '-15C rising'       # -- escapes a leading dash
```

**Upper case.** musl's `strftime` has no `%^`, and since it discards the whole result on an unknown conversion, `%^a`
would blank your status line rather than warn you. That format is refused with a message pointing at `-u`, which
upper-cases `a`–`z` and nothing else — so UTF-8 survives intact, every byte of a multi-byte sequence being `>= 0x80`.

**Interval alignment.** Updates are scheduled on absolute deadlines, `((now / interval) + 1) * interval`, via
`clock_nanosleep(CLOCK_REALTIME, TIMER_ABSTIME)`. So `-i 60` fires exactly on the minute and `-i 3` at `:00`, `:03`,
`:06`. A relative `sleep` drifts by one round trip per iteration and leaves a minute-resolution clock stale for up to a
full interval. Being on `CLOCK_REALTIME`, it also follows NTP steps and resume-from-suspend. The first update is
immediate and therefore unaligned; every one after lands on a boundary.

---

## Building

One script; `make` is not used.

```sh
./build.sh              # release -> bin/release/xrootclock  (default)
./build.sh debug        # unoptimised, debug info, UBSan
./build.sh run [args]   # build debug, then run it
./build.sh test [name]  # run the test suite, or one named test
./build.sh install      # copy the binary to $PREFIX/bin
./build.sh uninstall
./build.sh clean
```

Runnable from any directory, by absolute path, or through a symlink. A full rebuild takes ~0.2s, so there is no
incremental build: one compile-and-link, always from scratch. Every build regenerates `compile_commands.json` via
`clang -MJ` (no `bear` needed), so clangd sees the real flags and musl sysroot.

Notable flags, all verified against this toolchain: `-fstack-protector-strong` is free (identical stripped size), `-Os`
is immaterial (63120 bytes at every level from `-O1` to `-Oz`), and the debug build carries
`-fsanitize=undefined,local-bounds -fsanitize-minimal-runtime` — the only sanitizer that links against static musl.
Tested and rejected: `-static` (redundant), `-D_FORTIFY_SOURCE` and `-Wl,-z,relro,now` (no-ops here), `-static-pie`
(builds, but the result cannot run).

For a full ASan run, build a throwaway dynamic binary with the system compiler:

```sh
clang -std=c17 -D_GNU_SOURCE -g3 -fsanitize=address,undefined main.c -o /tmp/xrc
```

---

## Installing

```sh
./build.sh install          # -> ~/.local/bin/xrootclock
PREFIX=/opt ./build.sh install
./build.sh uninstall
```

`PREFIX` defaults to `~/.local`. `install` warns if the target directory is not on your `PATH`, comparing both sides
resolved so a different spelling of the same directory does not warn falsely.

It installs a **copy, not a symlink**: the installed binary must not change under you when you rebuild, and
`./build.sh clean` must not be able to leave a dangling link where your status bar used to be. `uninstall` does not
build first — removing something should not need a compiler.

---

## Tests

```sh
./build.sh test                    # the whole suite
./build.sh test args-interval      # one test
TEST_TIMEOUT=120 ./build.sh test   # slower machine
```

```
34 passed, 0 failed, 1 skipped, 0 errored
```

**Black box only** — every test runs the built binary and checks what it did; there are no C unit tests. `tests/fakex.c`
is a fake X server that answers the handshake and `GetInputFocus` and logs every request, so the suite never touches a
real display; it refuses to bind a socket someone is already serving, which makes reaching the real `:0` structurally
impossible. Tests assert against literal protocol numbers (18 / 31 / 39 / 43), never the program's own macros.

`tests/init.sh` follows gnulib's `init.sh`, the one coreutils uses, so its vocabulary carries over: `fail_`, `skip_`,
`framework_failure_`, `returns_`, `compare`, `retry_`, a per-test tmpdir with `trap` cleanup. Exit statuses mean **0**
pass, **1** fail, **77** skip, **99** the test's own setup broke.

`smoke-real-x` is the one test that touches your desktop. It is skipped unless `XRC_TEST_REAL_X=1`, saves and restores
the root `WM_NAME` from a `cleanup_` hook, and skips if another `xrootclock` is running.

See `AGENTS.md` for the rules a new test has to follow.

---

## Design notes

**Why not libX11.** The development machine has `libX11.so.6` at runtime but no X11 headers, and its musl toolchain is
static-only, so there is no musl-built libX11 to link. Speaking the protocol directly sidesteps that, and suits the job:
the program needs exactly two request types, where libX11 would bring a connection cache, an atom cache, locale
machinery and an event queue. The implementation covers the connection setup (little-endian prefix, `MIT-MAGIC-COOKIE-1`
auth, and parsing the setup reply far enough to reach the first screen's root window) and `ChangeProperty` (opcode 18,
`Replace`, `WM_NAME` atom 39, type `STRING` atom 31, format 8). Both atoms are predefined, so no `InternAtom` round trip
is needed.

**Syncing before exit.** `ChangeProperty` has no reply, so writing it and exiting immediately is a race the client
loses — the server sees the disconnect with the request still unread and discards it. Measured, `-1` landed **0 times
out of 10**. The program therefore sends `GetInputFocus` and blocks for its reply before closing; since one client's
requests are processed in order, that reply proves the property was applied. With it, `-1` lands 10 out of 10.
`xsetroot` avoids this because `XCloseDisplay()` round-trips. Only needed on the way out — inside the loop the sleep is
far longer than the server needs, so the steady state stays at three syscalls.

**Authentication.** The cookie comes from `$XAUTHORITY`, falling back to `$HOME/.Xauthority`, matched on method and
display number, preferring a `FamilyLocal` entry for this host and accepting `FamilyWild`. A missing or unreadable file
is not fatal — the connection is attempted anonymously and the server decides.

**`STRING` versus UTF-8.** The property is written as `STRING`, matching `xsetroot -name`. That is formally Latin-1, but
bytes pass through verbatim and dwm copies a `STRING` property raw, so UTF-8 renders fine in practice. Protocol-correct
UTF-8 would mean `_NET_WM_NAME` with `UTF8_STRING` and two `InternAtom` round trips. Not implemented.

**Local displays only.** `DISPLAY` must be `:0`, `unix:0` or `:0.0`. A TCP display is rejected: it needs a second
transport, and connection setup is precisely the cost this program exists to amortise.

**Failure behaviour.** `SIGINT`/`SIGTERM`/`SIGHUP` break the sleep and exit cleanly. `SIGPIPE` is ignored so a dead
server surfaces as a `write` error. Anything the server sends back is drained after each update, and an X error is
reported and fatal. Any failure exits non-zero.

---

## Project Structure

```
.
├── main.c                   # the program: options, format, the update loop
├── xwire.h                  # the X11 transport: DISPLAY, .Xauthority, connect, handshake, sync
├── build.sh                 # release | debug | run | test | install | uninstall | clean
├── tests/init.sh            # harness, modelled on gnulib/coreutils init.sh
├── tests/fakex.c            # fake X server, so tests never touch a real display
├── tests/*.sh               # 35 black-box tests
├── .clang-format            # clang-format style for the C files
├── .gitignore
├── .vscode/                 # lldb-dap launch config and build tasks, tracked on purpose
├── LICENSE                  # ISC
├── AGENTS.md                # conventions, rationale and the rules for changing things
└── README.md
```

---

## License

ISC — see [LICENSE](LICENSE). The same license slstatus and most of the suckless tools use.
