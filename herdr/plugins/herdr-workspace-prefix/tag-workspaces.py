#!/usr/bin/env python3
"""Keep the sidebar's metadata tokens in sync with herdr's state.

herdr styles a sidebar token statically: one `fg`, one `bold`, no variation by
focus, and no literal text (a bare string in `rows` is rejected -- custom tokens
must start with `$`). Both of the things the sidebar needs are therefore built
the same way: the STYLE stays fixed in config.toml, and this feeder decides
WHICH token a row carries. The name tokens are mutually exclusive, so exactly
one of them renders:

    selected ->  $prefix_active = the marker glyph (peach)
                 $name_active   = <label>  (white, bold)
    the rest ->  $name          = <label>  (white, regular)
                 and no prefix token at all

BOTH sidebar sections get this, and they read their tokens from different
scopes -- the same names, fed twice:

    [ui.sidebar.spaces]  <- WORKSPACE metadata, keyed by workspace; "selected"
                            means the focused workspace.
    [ui.sidebar.agents]  <- PANE metadata, keyed by the agent's pane; "selected"
                            means the focused pane. The label shown is still the
                            agent's workspace, which is what the built-in
                            `workspace` token used to render there.

Because the name is a token, the built-in `workspace` token is NOT in the rows:
it cannot be hidden on the selected row, so keeping it would print the name
twice. That is the cost of a focus-dependent name style -- while this feeder is
not running, rows show no name. herdr re-runs it from [[startup]], and the
`retag` plugin action re-seeds by hand.

Metadata is display-only and lives in the running server (it is absent from
session.json), so it is re-seeded on every start.

The sweep also names every workspace's unnamed first tab after this machine
(the MACHINE answer from theme.env) -- see name_first_tabs(). That one is a
real rename, persisted in the session, so it happens once per tab rather than
being re-seeded.

    tag-workspaces.py once     one sweep over the current state
    tag-workspaces.py watch    sweep, then keep following focus and renames
"""

import fcntl
import json
import os
import platform
import signal
import subprocess
import sys
import time

SOURCE = "dotfiles-workspace-prefix"
INTERVAL = 2.0

# Where install.sh keeps this machine's answers; MACHINE is the name the status
# bars carry, and now also what an unnamed first tab is called.
THEME_ENV = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "dotfiles",
    "theme.env",
)

# The marker drawn in front of the SELECTED row, in peach (the color lives in
# config.toml, this is only the character). Unselected rows get none.
ACTIVE_PREFIX_TEXT = ""

ACTIVE_PREFIX_TOKEN = "prefix_active"
IDLE_NAME_TOKEN = "name"
ACTIVE_NAME_TOKEN = "name_active"

OWNED_TOKENS = (ACTIVE_PREFIX_TOKEN, IDLE_NAME_TOKEN, ACTIVE_NAME_TOKEN)

# Tokens earlier versions of this feeder wrote. They are no longer rendered, but
# they persist in a running server until cleared, so a sweep sheds them.
LEGACY_TOKENS = ("aa", "bb")


def herdr_bin():
    candidate = os.environ.get("HERDR_BIN_PATH") or "herdr"
    for path in (candidate, os.path.expanduser("~/.local/bin/herdr")):
        try:
            subprocess.run(
                [path, "--version"], capture_output=True, timeout=5, check=True
            )
            return path
        except Exception:
            continue
    return None


def query(binary, *args):
    """Run a herdr CLI query and return its `result`, or None."""
    try:
        out = subprocess.run(
            [binary, *args], capture_output=True, text=True, timeout=5
        ).stdout
        return json.loads(out)["result"]
    except Exception:
        # A server that is down or mid-restart is normal; the next sweep retries.
        return None


def desired_tokens(focused, label):
    if focused:
        return {ACTIVE_PREFIX_TOKEN: ACTIVE_PREFIX_TEXT, ACTIVE_NAME_TOKEN: label}
    return {IDLE_NAME_TOKEN: label}


def reconcile(binary, scope, target_id, current, wanted):
    """Push `wanted` onto a workspace or pane, clearing whatever it replaces."""
    current = current or {}
    stale = [
        name
        for name in OWNED_TOKENS + LEGACY_TOKENS
        if name not in wanted and current.get(name) is not None
    ]
    if not stale and all(current.get(k) == v for k, v in wanted.items()):
        return

    args = [binary, scope, "report-metadata", target_id, "--source", SOURCE]
    for name, value in wanted.items():
        # `--token NAME=VALUE` splits on the first `=`, so a label containing one
        # still lands intact on the right-hand side.
        args += ["--token", f"{name}={value}"]
    for name in stale:
        args += ["--clear-token", name]
    try:
        subprocess.run(args, capture_output=True, timeout=5)
    except Exception:
        pass


def machine_name():
    """The MACHINE answer from theme.env, or the short hostname without it."""
    try:
        with open(THEME_ENV, encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("MACHINE="):
                    value = line.split("=", 1)[1].strip().strip("'\"")
                    if value:
                        return value
    except OSError:
        pass
    return platform.node().split(".")[0]


def name_first_tabs(binary):
    """Call every workspace's unnamed first tab after this machine.

    A tab with no custom name shows its number, and herdr has no config for a
    default name -- so tab 1 opens as the label "1" everywhere. Unlike the
    display metadata above, a rename is real state: it persists in the session,
    so this fires once per tab and then matches nothing. Only `number == 1 and
    label == "1"` is touched -- a tab the user has renamed keeps their name.
    """
    machine = machine_name()
    if not machine:
        return
    result = query(binary, "tab", "list")
    if result is None:
        return
    for tab in result.get("tabs", []):
        if tab.get("number") != 1 or tab.get("label") != "1":
            continue
        try:
            subprocess.run(
                [binary, "tab", "rename", tab["tab_id"], machine],
                capture_output=True,
                timeout=5,
            )
        except Exception:
            pass


def sweep(binary):
    result = query(binary, "workspace", "list")
    if result is None:
        return
    labels = {}
    for workspace in result.get("workspaces", []):
        workspace_id = workspace["workspace_id"]
        label = workspace.get("label") or workspace_id
        labels[workspace_id] = label
        reconcile(
            binary,
            "workspace",
            workspace_id,
            workspace.get("tokens"),
            desired_tokens(workspace.get("focused"), label),
        )

    # Before the pane pass, which returns early when its own query fails.
    name_first_tabs(binary)

    # The agents section keys off panes, and only agent panes appear there;
    # tagging the rest would be invisible work.
    result = query(binary, "pane", "list")
    if result is None:
        return
    for pane in result.get("panes", []):
        if not pane.get("agent"):
            continue
        label = labels.get(pane.get("workspace_id"), pane.get("workspace_id") or "?")
        reconcile(
            binary,
            "pane",
            pane["pane_id"],
            pane.get("tokens"),
            desired_tokens(pane.get("focused"), label),
        )


def lockfile_path():
    # Deliberately NOT TMPDIR: two processes must agree on this path, and herdr's
    # own environment need not match the shell's. XDG_RUNTIME_DIR is honoured only
    # when it actually exists -- it is frequently set to a path that does not.
    runtime = os.environ.get("XDG_RUNTIME_DIR") or ""
    if not runtime or not os.path.isdir(runtime):
        runtime = "/tmp"
    session = os.environ.get("HERDR_SESSION") or "default"
    return os.path.join(runtime, f"herdr-workspace-prefix.{session}.lock")


def acquire_singleton_lock():
    """Hold an exclusive lock for as long as this watcher runs.

    An advisory lock, not a pidfile: the kernel drops it when the holder dies, so
    there is no stale state to reason about and no window where two starts each
    decide the other is absent. The handle is returned only to keep it open --
    closing it would release the lock.
    """
    path = lockfile_path()
    try:
        handle = open(path, "a+", encoding="utf-8")
    except OSError:
        return None, True  # cannot lock; better to run than to stay silent
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None, False
    handle.truncate(0)
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    return handle, True


def watch(binary):
    # One watcher per session: herdr runs [[startup]] on every start, and a
    # watcher may already be following the session that is running now.
    handle, acquired = acquire_singleton_lock()
    if not acquired:
        return 0

    def shutdown(_signum, _frame):
        # Explicit exit: a handler that only cleaned up would let the loop resume,
        # and the watcher would survive its own shutdown.
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGHUP, shutdown)

    try:
        while True:
            sweep(binary)
            time.sleep(INTERVAL)
    finally:
        if handle is not None:
            handle.close()
    return 0


def main():
    binary = herdr_bin()
    if binary is None:
        return 0
    mode = sys.argv[1] if len(sys.argv) > 1 else "once"
    if mode == "once":
        sweep(binary)
        return 0
    if mode == "watch":
        return watch(binary)
    print(f"usage: {sys.argv[0]} <once|watch>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
