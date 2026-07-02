# specs-jetson/etc — power / fan / clocks (nvpmodel & jetson_clocks notes)

`nvpmodel` and `jetson_clocks` are **L4T userspace tools** (part of the
`nvidia-l4t-*` BSP packages). They do NOT exist on the mainline kernel flavor
and are NOT baked into this image — this file documents the equivalents.

## Mainline kernel flavor (what this image ships)

* **CPU frequency**: `ARM_TEGRA186_CPUFREQ` is enabled; the standard
  `schedutil`/`performance` governors apply. Pin performance with:
  `echo performance > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`
* **Thermal / fan**: `TEGRA_SOCTHERM` + `SENSORS_PWM_FAN` are enabled; the
  devkit fan is a pwm-fan cooling device driven by the DT's thermal zones.
  `lm-sensors` (baked) reads the zones.
* **Power ceiling (nvpmodel-equivalent)**: mainline has no MAXN/15W/7W mode
  switch — the power envelope is whatever the DT + cpufreq governor produce.
  For a hard cap, offline cores (`echo 0 > /sys/devices/system/cpu/cpuN/online`)
  and cap `scaling_max_freq`.

## L4T kernel flavor (documented, not automated)

Once a node is on the L4T stack (see ../installer/TEGRAFLASH.md):

* `sudo nvpmodel -m 0` — MAXN; `-m 1` — 15 W; `-m 2` — 7 W (Orin Nano table).
* `sudo jetson_clocks` — pin all clocks to the current nvpmodel ceiling.
* `sudo jetson_clocks --fan` — force fan to max.

These write through `/etc/nvpmodel.conf` and the BSP's sysfs nodes; keep them
OUT of OpenRC runlevels until the L4T flavor is hardware-validated.
