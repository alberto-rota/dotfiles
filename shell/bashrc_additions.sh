#!/bin/bash
# MOVED: this file is now shell/shellrc_additions.sh, because ~/.zshrc sources
# it too and a name with "bashrc" in it was a lie on half the machines.
#
# Kept only as a redirect. A machine set up before the rename has the old path
# baked into its ~/.bashrc, and without this every new shell there would open
# with "No such file or directory" and none of the aliases, PATH or prompt --
# until install.sh is re-run, which rewrites that line to the new path.
# Delete this once every machine has had a run of install.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/shellrc_additions.sh"
