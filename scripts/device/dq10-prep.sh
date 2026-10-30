#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# dq10-prep.sh - runs ON THE STICK (Android root shell) at the START of the procedure and again right
# before staging/commit.  NOT EXECUTED by the build agent.  Idempotent.  Runtime-only changes (lost on reboot).
# EDIT THIS: the subnet of the isolated network the stick is allowed to talk to (e.g. the laptop's hotspot subnet).
# 192.0.2.0/24 is a documentation range and is only a placeholder.
LAN=192.0.2.0/24
# 1) egress block (re-applied every time; the chain is flushed and rebuilt, the jump is inserted once)
iptables -N DQ10BLOCK 2>/dev/null
iptables -F DQ10BLOCK
iptables -A DQ10BLOCK -o lo -j RETURN
iptables -A DQ10BLOCK -d "$LAN" -j RETURN
iptables -A DQ10BLOCK -j REJECT --reject-with icmp-port-unreachable
iptables -C OUTPUT -j DQ10BLOCK 2>/dev/null || iptables -I OUTPUT 1 -j DQ10BLOCK
# IPv6: block everything except loopback (the stick should not have v6 egress either)
ip6tables -N DQ10BLOCK6 2>/dev/null
ip6tables -F DQ10BLOCK6
ip6tables -A DQ10BLOCK6 -o lo -j RETURN
ip6tables -A DQ10BLOCK6 -j REJECT
ip6tables -C OUTPUT -j DQ10BLOCK6 2>/dev/null || ip6tables -I OUTPUT 1 -j DQ10BLOCK6
# 2) stop things that could write to the staging area or interfere: OTA engine (Virtual A/B would allocate the
#    _b partitions inside the free tail of super!) and the vendor/malware root components
for s in update_engine ttyunos qw rootaccess; do stop $s 2>/dev/null; done
pkill -f polkitu_android 2>/dev/null
am force-stop com.master.apps 2>/dev/null
am force-stop com.master.tv.market 2>/dev/null
# 3) free some RAM (41 MB were free earlier): drop page cache
sync; echo 3 > /proc/sys/vm/drop_caches
# 4) report (read by the operator)
echo "== OUTPUT chain"; iptables -S OUTPUT | head -3; iptables -S DQ10BLOCK
for s in update_engine ttyunos qw rootaccess; do echo "svc $s: $(getprop init.svc.$s)"; done
ps -A | grep -E "polkitu|com.master|ttyunos| qw$" || echo "no agent processes left"
free -m | head -2
