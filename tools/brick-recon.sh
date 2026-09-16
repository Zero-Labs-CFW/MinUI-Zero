#!/bin/sh
# brick-recon.sh — gather CPU freq / governor / thermal facts on the TrimUI Brick (tg5040)
# so we can replace the assumed values in docs/thermal-governor-design.md with real ones.
#
# Run over a shell on the device, twice:
#   1) idle at the menu        -> baseline
#   2) during a demanding game -> load profile
# Then commit both outputs. Written for busybox ash (no bashisms).

hdr()  { printf '\n==== %s ====\n' "$*"; }
dump() { # dump <label> <path>
  if [ -r "$2" ]; then printf '%-26s %s\n' "$1:" "$(cat "$2" 2>/dev/null)"
  else              printf '%-26s (absent)\n' "$1:"; fi
}

hdr "Kernel / cores"
dump "kernel" /proc/version
printf '%-26s %s\n' "nproc:" "$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"

hdr "cpufreq policies (the real OPP steps)"
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$p" ] || continue
  printf -- '-- %s\n' "$p"
  dump "affected_cpus"       "$p/affected_cpus"
  dump "scaling_driver"      "$p/scaling_driver"
  dump "scaling_governor"    "$p/scaling_governor"
  dump "available_governors" "$p/scaling_available_governors"
  dump "available_freqs"     "$p/scaling_available_frequencies"
  dump "cpuinfo_min_freq"    "$p/cpuinfo_min_freq"
  dump "cpuinfo_max_freq"    "$p/cpuinfo_max_freq"
  dump "scaling_cur_freq"    "$p/scaling_cur_freq"
done

hdr "Per-core view (MinUI only pokes cpu0 — is the policy cluster-wide?)"
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
  [ -d "$c" ] || continue
  printf '%-8s gov=%-12s cur=%s kHz\n' "$(basename "$(dirname "$c")")" \
    "$(cat "$c/scaling_governor" 2>/dev/null)" "$(cat "$c/scaling_cur_freq" 2>/dev/null)"
done

hdr "Is an 'auto' governor present? (NextUI hands off to one)"
gl=" $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors 2>/dev/null) "
case "$gl" in
  *" auto "*) echo "yes — 'auto' exists, can reuse it" ;;
  *)          echo "no  — closed-loop in userspace, or patch the kernel" ;;
esac

hdr "Voltage / OPP / undervolt mechanism (spike: CAN we write CPU voltage at runtime?)"
# READ-ONLY probe. This script NEVER writes a voltage. See docs/archive/undervolt-spike-design.md.
for path in /sys/kernel/debug/opp /sys/class/devfreq /sys/class/regulator /sys/firmware/devicetree; do
  [ -e "$path" ] && echo "present: $path" || echo "absent:  $path"
done

echo "-- regulators (name, current uV, min/max, node perms = writability) --"
for r in /sys/class/regulator/regulator.*/; do
  [ -d "$r" ] || continue
  perm=$(ls -l "$r/microvolts" 2>/dev/null | cut -c1-10)
  printf '  %-14s name=%-18s uV=%-9s [%s..%s] microvolts-perms:%s\n' \
    "$(basename "$r")" "$(cat "$r/name" 2>/dev/null)" "$(cat "$r/microvolts" 2>/dev/null)" \
    "$(cat "$r/min_microvolts" 2>/dev/null)" "$(cat "$r/max_microvolts" 2>/dev/null)" "$perm"
done

echo "-- cpu regulator + cpufreq driver (is freq scaling OPP/voltage-backed?) --"
dump "scaling_driver"  /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
dump "cpu-supply name" /sys/devices/system/cpu/cpu0/cpu-supply/name

echo "-- OPP table (the freq<->voltage map = the undervolt target), if exposed --"
for d in /sys/kernel/debug/opp/*/ ; do
  [ -d "$d" ] || continue
  echo "  $d"
  for f in "$d"*; do
    [ -f "$f" ] || continue
    printf '    %-22s %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
  done
done

echo "VERDICT INPUT: if every regulator microvolts node above is read-only (r--) and no OPP"
echo "  voltage is writable, runtime undervolt is NOT possible on this kernel -> needs a custom"
echo "  DTB/kernel (patched OPP voltages). If a CPU-rail regulator is writable, a bounded runtime"
echo "  undervolt is feasible. Record this output in docs/archive/undervolt-spike-design.md."

hdr "Thermal zones (find which one is the CPU)"
for z in /sys/class/thermal/thermal_zone*; do
  [ -d "$z" ] || continue
  printf '%-20s type=%-16s temp=%s mC\n' "$(basename "$z")" \
    "$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"
done

hdr "Live sample: temp + cpu0 freq, 1s x 20 (idle now; re-run mid-game)"
ZONE=/sys/class/thermal/thermal_zone0/temp   # adjust to the CPU zone from the list above
FREQ=/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
i=0
while [ "$i" -lt 20 ]; do
  printf 't=%2ss  temp=%s mC  freq=%s kHz\n' "$i" \
    "$(cat "$ZONE" 2>/dev/null)" "$(cat "$FREQ" 2>/dev/null)"
  i=$((i + 1)); sleep 1
done
