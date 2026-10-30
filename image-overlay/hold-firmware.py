#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Mark armbian-firmware* packages as 'hold' in a dpkg status file (offline), so apt does not
re-install the ~440 MB of firmware that build-image.sh pruned."""
import sys
p = sys.argv[1]
paras = open(p, encoding="utf8").read().split("\n\n")
n = 0
for i, para in enumerate(paras):
    first = para.split("\n", 1)[0]
    if first.startswith("Package: armbian-firmware"):
        paras[i] = para.replace("Status: install ok installed", "Status: hold ok installed")
        n += 1
open(p, "w", encoding="utf8").write("\n\n".join(paras))
print("dpkg hold set on", n, "armbian-firmware* package(s)")
