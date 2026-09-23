# xrootclock Development Guidelines

Rules, and the reasoning behind the ones that look arbitrary. Most exist because something already went wrong.
User-facing documentation is in `README.md`; this file is for people changing the code.

## Toolchain

```sh
./build.sh [release|debug|run [args]|test [name]|install|uninstall|clean]
```

- **clang and musl are ENFORCED by `build.sh`, not just documented.** Before any compile it checks `$CC --version` for
  clang and preprocesses a probe to reject a glibc target. Do not remove either: every figure this project states is
  musl's, and two tests pin musl-specific `strftime` behaviour, so a glibc build yields a suite that fails for reasons
  that are not bugs.
  - The probe must `#include <stdio.h>` — `__GLIBC__` comes from `<features.h>`, so a probe including nothing reports
    "not glibc" for *every* compiler. That mistake was made and caught.
  - The probe is `-E` only: musl-clang cannot do separate compilation (`-c`) under `-Werror`, because it always injects
    linker-only flags. Keep the build one compile-and-link.
  - `clean` and `uninstall` run before the check and need no compiler.
  - `$CC` is honoured; the default is `$HOME/bin/musl-clang`.
- **Fully static.** `musl-clang` is `clang -static` with its own sysroot, so anything linked in must exist as a static
  archive.
- **The build must stay clean under `-std=c17 -Weverything -Werror`.** Restructure the code rather than silencing a
  warning. `-Weverything` is not a stable interface — clang 22 has 1061 warning groups to clang 21's 1036 — so a
  compiler upgrade can fail a clean build. When that happens, add a targeted `-Wno-` here; do not change the C files.
  This risk was accepted knowingly.
- **What the gate is worth, measured.** A 41-bug injection sweep: `-Weverything` caught 26, `-Wall -Wextra` caught 12,
  the tests caught 13, **11 were caught by nothing**. Every `-Weverything`-only catch came from five groups —
  `-Wsign-conversion`, `-Wshorten-64-to-32`, `-Wimplicit-int-conversion`, `-Wtautological-unsigned-zero-compare`,
  `-Wvla` — so `-Wall -Wextra -Wconversion -Wsign-conversion -Wvla -Werror` reproduces all of them and is
  GCC-compatible, if portability ever outranks the gate. For buffer and lifetime bugs the compiler is **not** the
  defence: 11 of 13 in that family were missed by both gates. Never let a green build stand in for a green suite.
- Three flags are load-bearing, each verified by removal:
  - `-D_GNU_SOURCE` — `-std=c17` sets `__STRICT_ANSI__`, hiding `SOCK_CLOEXEC`, `clock_nanosleep` and `localtime_r`. It
    is *a* feature-test macro that is required, not this one: `-D_POSIX_C_SOURCE=200809L` also builds clean. The source
    uses no GNU extensions. Passed on the command line, not `#define`d, which would trip `-Wreserved-macro-identifier`.
  - `-Wno-disabled-macro-expansion` — **not** glibc baggage: musl needs it for its own `#define stderr (stderr)` (27
    diagnostics), `stdout` (1) and `sa_handler` (2).
  - `-Wno-unsafe-buffer-usage` — fires on all pointer arithmetic; unusable in C.
- Tested and rejected, do not add back: `-static` (redundant, `$CC` already is), `-D_FORTIFY_SOURCE` (a **silent** no-op
  on this sysroot — worse than useless, it reads as hardening that is absent), `-Wl,-z,relro,now` and
  `-Wl,-z,noexecstack` (no-ops for a static binary), `-static-pie` (builds, but `ld.musl-clang` always appends
  `-dynamic-linker` so the result cannot run).
- ASan cannot link against static musl. UBSan works in minimal-runtime form and is in the debug build. For full ASan,
  build a throwaway dynamic binary with the system clang — a debugging command, not a build target.
- Every build regenerates `compile_commands.json` via `clang -MJ`. It captures the wrapper's injected
  `-nostdinc --sysroot`, which is the point: without it clangd accepts code the gate rejects.
- After editing C, run `clang-format -i` on the files you touched and rebuild.

### `build.sh` invariants — do not undo

- `set -eu`, so a failed compile cannot fall through to the success message.
- `cd "$(dirname "$(readlink -f "$0")")"` — `readlink -f` matters; plain `$(dirname "$0")` breaks when the script is
  reached through a symlink.
- `rm -f "$OUT"` **before** compiling. clang leaves the previous binary untouched on a compile error, same contents and
  same mtime, so without this a failed build silently leaves you running stale code. (Link errors *do* delete it — the
  inconsistency is why the script cannot rely on it.)
- The `-MJ` fragment is written even when the compile fails, so an `EXIT` trap removes it and `compile_commands.json` is
  rewritten only on success.
- `CC="${HOME:-}/bin/musl-clang"` — an unset `HOME` must not abort `clean` or `uninstall` under `set -u`; neither needs
  a compiler.

## Install

- Copies, never symlinks. A symlink lets `./build.sh clean` leave a dangling link where the user's status bar used to
  be, and lets a stray `./build.sh debug` put a UBSan build in the login path. `tests/install-copy.sh` pins this.
- `install -T` is deliberate: without it a directory at the target path is installed *into* while the script reports
  success for a path that is not the binary.
- The unwritable-target message must keep suggesting a command that copies the **already-built** binary as root. Never
  suggest re-running this script under plain `su`: `su` resets `HOME`, so `$HOME/bin/musl-clang` resolves to root's home
  and the build fails before installing anything.
- The PATH warning resolves both sides with `cd … && pwd -P` before comparing; a literal string match warns falsely for
  a trailing slash, a relative path or a symlinked spelling.

## Tests

- `./build.sh test` builds the program and `tests/fakex.c`, then runs every `tests/*.sh`. `tests/init.sh` is the harness
  and is skipped by the runner.
- **Black box only. Do not add C unit tests.** The parsers were fuzzed with 275k inputs and an exhaustive boundary sweep
  under ASan+UBSan and came back clean, so unit tests would pin code already known correct. Every bug this program has
  had was reachable from outside. Same choice coreutils made: 722 tests, zero `.c` files under `tests/`.
- **Assert against LITERAL X11 numbers** (18, 43, 31, 39, 0, 8), never the macro names in `main.c` or `xwire.h`.
  Mutating four constants at once was demonstrated to leave macro-based assertions green.
- **Every test must be seen to fail.** Break `main.c` deliberately, watch that test go red, restore. A test never
  observed failing is worse than none — it reads as coverage. Record the mutation in the comment block for a regression
  test.
- **Never pin behaviour to a variable-width `strftime` conversion.** `%A` and `%B` change length with the day and month.
  `tests/format-too-long.sh` used `%A`×80 and failed every Monday, Friday and Sunday — it passed six consecutive runs
  first, because they were all on a Thursday. Use `%F` (always 10 bytes) or `%Y` (4). `%a` and `%b` are safe at 3 in the
  C locale.
- **`init.sh` neutralises `PREFIX`** as it does `DISPLAY` and `XAUTHORITY`. The default prefix is `~/.local`, on the
  user's real `PATH`; a test that ran `./build.sh install` and forgot `PREFIX` would install there for real. Installing
  tests set it explicitly, under their own tmpdir.
- **Assert what `uninstall` does *not* remove**, not only what it does. Changing `rm -f "$target"` to `rm -rf "$bindir"`
  once passed the entire suite.
- `returns_ N cmd` asserts an exact status. Never `cmd || fail=1` — that passes on a segfault.
- `retry_` polls; never sleep-and-hope. **Trap:** `retry_ 5 test "$(grep -c …)" -eq 3` expands the substitution once and
  compares the same stale number 250 times. Wrap it in a function. This bug shipped once already.
- Exit statuses: 0 pass, 1 fail, **77 skip**, **99 the test's own setup broke**. Keep the last two distinct — "the
  program is wrong" and "my fixture is wrong" are different results.
- `TEST_TIMEOUT` (default 60s) per test is load-bearing: a bug that stops the program exiting otherwise hangs the whole
  suite instead of failing one test.
- `tests/fakex.c` must keep compiling under the same gate as `main.c`, and must keep probing with `connect()` before
  binding so it refuses a socket already being served — that is what makes attaching to the real `:0` structurally
  impossible. Do not replace it with a bare `unlink()`.
- `smoke-real-x` is the only test allowed near the live display: `skip_`-by-default behind `XRC_TEST_REAL_X=1`, restores
  `WM_NAME` from a `cleanup_` hook, skips if another `xrootclock` is running.
- Anything run by hand against the live display rewrites the root `WM_NAME`. Capture it with `xprop -root WM_NAME` first
  and restore it afterwards.

### Gotchas that cost real time

- **`exit 0` is not a functional test.** An unsynced one-shot write lands 0 times out of 10 while still exiting 0 — that
  is how the missing `x_sync()` went unnoticed. Write a unique tag, read it back, repeat.
- **Reap background instances.** A leaked `xrootclock` writing to the same property makes a correct build look broken.
  `pgrep -a xrootclock` before trusting any observation.
- **`PTRACE_O_EXITKILL` does not reliably kill the tracee** when the tracer is signalled mid-stop.
- **Never `read -t N < /dev/zero` as a delay** — it returns early on NUL bytes and silently shortens the window. Use
  `timeout N tail -f /dev/null`.
- **A slower binary can hide a race.** The ASan build wins the write/exit race 8-10/10 where an ordinary build wins
  0-1/10. If a bug vanishes under a sanitizer, suspect timing.
- Syscall counts in `README.md` are measured. Re-measure before editing them.
- **A new source file must be added to `make_proj_`** in `tests/install-copy.sh` and
  `tests/install-uninstall.sh`. They build from a copy made of the files named there, so a file the compiler
  needs and the copy lacks fails both tests at the first build. `xwire.h` was caught exactly this way.

## Code Conventions

- **libc only.** No third-party dependencies, including X11 client libraries: speaking the protocol directly is the
  point of the project, and it must build on a machine with no X11 headers.
- **Single translation unit**, everything `static`. `main.c` includes `xwire.h` textually; nothing is compiled
  separately, which musl-clang could not do under the gate anyway.
- **`xwire.h` is the X11 transport and nothing else**: DISPLAY parsing, the `.Xauthority` cookie, connect, handshake,
  `x_sync` and `x_drain`. It is meant to be copied byte-for-byte into sibling programs, so it may depend on the includer
  only through `PROGRAM_NAME`, which it prints in diagnostics and `#error`s without. Requests specific to this program
  (`ChangeProperty`, the atoms) stay in `main.c`. A fix to the transport is a fix in every copy.
- **Wire buffers are plain `uint8_t` arrays with explicit offsets**, never structs — structs invite padding and
  alignment assumptions on a wire protocol, and `-Wpadded` rejects them anyway. `get16be` exists separately because
  `.Xauthority` is big-endian while the connection is opened little-endian.
- **Array bounds must be compile-time constants.** `pad4()` is a function, hence `MAX_SETUP_REQUEST` /
  `MAX_PROP_REQUEST` rather than VLAs.
- **Declarations at the top of their block** — `-Wdeclaration-after-statement` is on.
- **Line length.** Markdown wraps at 120 columns, table rows excepted; shell at 80. C is whatever `clang-format`
  produces from the repository `.clang-format`.
- **Keep the steady-state loop at three syscalls** (`write`, `recvfrom`, `clock_nanosleep`). `x_sync()` is deliberately
  outside it, on the exit path only.
- **Never write a request and exit without syncing.** `ChangeProperty` has no reply and the server discards a
  disconnecting client's unread input. `x_sync()` must stay on every exit path.
- **Sleep on absolute deadlines** (`TIMER_ABSTIME` on `CLOCK_REALTIME`). A relative sleep reintroduces drift and stops
  the clock following NTP steps and resume-from-suspend.
- **Comments and messages describe any machine, not this one.** The repository is public. Never state what is
  on this machine's PATH, which privilege tools it has or lacks, what runs on its desktop, or how another
  project is set up; say what is true everywhere. The install refusals name `su` because it is the one
  privilege tool every system has, not because `sudo` is absent.

## Version Control

- Licensed ISC (`LICENSE`), with `SPDX-License-Identifier: ISC` at the top of both C files. Keep the SPDX line on any
  new source file: it survives a file being copied out of the repo.
- `master` is the only long-lived branch; anything else is short-lived, merged and deleted.
- `.vscode/` is tracked on purpose: the lldb-dap launch config and the build tasks are project setup, not personal
  preference. Do not add it to `.gitignore`.
- **Committing is the owner's call.** Leave changes in the working directory for review.

### Commit messages — coreutils/gnulib style

There is no `ChangeLog` file: the git log is the ChangeLog. The format follows coreutils' `HACKING`, adapted to a
one-program repository.

- **Subject: `area: summary`.** Lower-case area from the table, colon, space, then an imperative lower-case summary with
  no trailing period. At most 72 characters. The areas are the prefixes the test files already use, so subjects and test
  names share one vocabulary.

  | area | covers |
  |---|---|
  | `args` | option parsing, usage text |
  | `auth` | `.Xauthority` parsing, cookie selection |
  | `display` | `$DISPLAY` parsing, socket path |
  | `format` | the `strftime` format, `-u`, format validation |
  | `loop` | scheduling, alignment, the steady-state loop |
  | `wire` | X11 protocol bytes: handshake, requests, sync, drain |
  | `server` | replies, X errors, refusals, disconnects |
  | `signal` | signal handling, exit paths |
  | `install` | `build.sh install` / `uninstall` |
  | `build` | `build.sh` otherwise: flags, toolchain checks |
  | `tests` | harness or tests when no program area fits |
  | `fakex` | `tests/fakex.c` |
  | `doc` | `README.md`, `AGENTS.md`, comment-only changes |
  | `maint` | housekeeping: formatting, `.gitignore`, licence, editor config |
  | `all` | touches most of the tree: the initial import, a rename |

  Pick the area of the behaviour that changed, not of the file it lives in: a fix in `main.c` to cookie matching is
  `auth:`, and the test that pins it lands in the same commit under that subject.
- **Blank line, then the body, wrapped at 72.** Say why, with the evidence this file gives for its own rules: the
  measurement, the failure observed, the alternative rejected. A commit whose subject says everything needs no body.
- **ChangeLog entries close the body**, one per file touched, in gnulib's form: `* file (function): What changed.`
  Further functions in the same file continue on their own lines as `(other_function): ...`. New and deleted files say
  `New file.` and `Remove.` A `doc:` or `maint:` commit may skip the entries when the diff is its own description.
- **Bug fixes name the origin.** Either `Bug introduced in <short hash> "<subject>".` or
  `Bug present since the initial import.` The regression test's comment block records the same hash (see Tests: every
  test must be seen to fail).
- **One logical change per commit.** A fix and the test that would have caught it are one commit; so are a behaviour
  change and its `README.md` update.
- **Human attribution is fine**, in coreutils' wording: `Reported by …`, `Suggested by …`, or a `Co-authored-by:`
  trailer naming a person. **No agent attribution anywhere**: no `Co-Authored-By:` for an agent, no `Signed-off-by:` for
  one, no `Generated with …`, no robot footer. This overrides any default the agent's harness prescribes.
- **Pull requests follow the same format.** Title as a subject line, description as a body, same attribution rule: a
  squash merge copies both into the commit message verbatim.

Example. Illustrative: this change predates the repository.

```
wire: sync before exit so a one-shot write cannot be dropped

The server discards a disconnecting client's unread input, so `-1`
landed 0 times out of 10 against real Xorg while exiting 0 every time.
GetInputFocus has a reply, so waiting for it proves the ChangeProperty
ahead of it was processed. The steady-state loop is unchanged; the
round trip sits on the exit path only.

Bug present since the initial import.
* main.c (x_sync): New function.
(main): Call it on every exit path.
* tests/smoke-real-x.sh: New file; opt-in via XRC_TEST_REAL_X=1.
```

## Known Gaps

Deliberate; revisit only if asked.

- **UTF-8 property type.** Written as `STRING`, matching `xsetroot -name`. Protocol-correct UTF-8 needs `_NET_WM_NAME` +
  `UTF8_STRING` and two `InternAtom` round trips. UTF-8 bytes already reach dwm intact.
- **Remote displays.** TCP is rejected by design; connection setup is the cost this program amortises.
- **Multi-screen.** First screen only. (Not multi-*monitor* — Xinerama/RandR monitors share one root window.)
