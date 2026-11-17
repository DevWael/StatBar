# StatBar

A macOS menu bar app that shows CPU, memory, GPU, disk, network, temperatures, fan speed and power draw, updated every second.

It is written in Swift with AppKit and has no dependencies. Sensors are read directly from Mach, IOKit, the SMC and IOReport. The app binary is about 180 KB.

## Requirements

- Apple Silicon Mac. Tested on a MacBook Pro M1 Pro running macOS 27.
- Xcode or the Xcode command line tools (for `swiftc`).

## Build and run

```sh
./build.sh            # builds build/StatBar.app
./build.sh install    # also copies it to ~/Applications
open build/StatBar.app
```

The app is signed ad hoc, so it only runs on the machine that built it unless you sign it with your own certificate.

## Using it

Click the icon to open the detail panel. Under **Show in Menu Bar**, tick the metrics you want next to the icon. With nothing ticked the bar shows only the icon. Your picks are saved in `~/Library/Preferences/local.statbar.plist`.

| Metric | Panel | Menu bar |
| --- | --- | --- |
| CPU usage | total, P-cores, E-cores | total % |
| Memory | used of total, pressure, swap | used GB |
| GPU usage | % | % |
| Disk activity | read and write per second | R/W per second |
| Network activity | down and up per second | down/up per second |
| CPU temperature | hottest core | hottest core |
| GPU temperature | hottest sensor | hottest sensor |
| Battery temperature | °C | °C |
| Fan speed | each fan, rpm | fastest fan, rpm |
| System power | whole machine, W | W |
| GPU power | W | W |
| Charger input | adapter rating and current draw, W | current draw, W |
| Battery charge/discharge | charging or discharging, W | +/- W |

## Resource use

Sensors are only read for what is on screen: the ticked metrics, plus everything while the panel is open. Nothing runs when the bar shows only the icon and the panel is closed, or when the displays are asleep.

Measured on the M1 Pro:

| State | CPU time per minute | Memory (RSS) |
| --- | --- | --- |
| Icon only, panel closed | 0 s | ~70 MB |
| 4 metrics in the bar | ~1.3 s | ~80 MB |

On macOS 27 most of the cost of updating a menu bar item every second sits in AppKit, not in the app. A test app that only changes a status item's title once a second used 1.28 s of CPU per minute on the same machine. StatBar's sensor reads and drawing add about 0.06 s per minute on top of that. Most of the RSS is AppKit's shared memory.

## Where the numbers come from

| Metric | Source |
| --- | --- |
| CPU usage | `host_processor_info` tick deltas |
| Memory | `host_statistics64`; used = app + wired + compressed, as in Activity Monitor |
| Swap, pressure | `vm.swapusage`, `kern.memorystatus_vm_pressure_level` |
| GPU usage | `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %` |
| Disk | `IOBlockStorageDriver` → `Statistics` byte counters |
| Network | `NET_RT_IFLIST2` sysctl, `en*` interfaces only |
| CPU temperature | SMC key `TCMz` (hottest CPU core), falling back to the max of `Tp*`/`Te*` keys |
| GPU temperature | max of SMC `Tg*` keys |
| Battery temperature | SMC `TB0T` |
| Fans | SMC `FNum`, `F<n>Ac` |
| System power | SMC `PSTR` |
| Charger input | SMC `PDTR`; adapter rating from `AppleSmartBattery` → `AdapterDetails` |
| Battery power | `AppleSmartBattery` `Voltage` × `Amperage` |
| GPU power | IOReport `Energy Model` → `GPU Energy` |

Each SMC read takes about 250 µs, so the app reads as few keys as it can. CPU temperature reads one key instead of the ~30 per-core keys.

## Known limits

- **No CPU power.** On macOS 27 the IOReport `Energy Model` counters for CPU, ANE and DRAM do not change, so there is nothing to read. GPU power and whole-system power still work.
- The P/E-core split assumes efficiency cores are numbered first, which holds on M1, M2 and M3 chips.
- The temperature key prefixes (`Tp`, `Te`, `Tg`) match the M1 Pro. Other chips may use different keys and show `–`.
- Network totals skip VPN tunnels (`utun*`) so traffic isn't counted twice. That also means traffic on non-`en` interfaces isn't shown.
- Fans that are stopped show as `off`, which is normal for an M1 Pro under light load.

## Layout

```
Sources/
  Bridge.h      SMC struct and IOReport declarations
  SMC.swift     SMC connection, key reads, value decoding
  Energy.swift  IOReport energy channel → watts
  Sampler.swift reads only the sources the shown metrics need
  Format.swift  number formatting for the bar and the panel
  Views.swift   menu bar image and detail panel
  main.swift    status item, menu, timer
Resources/
  AppIcon.icns  app icon, made by tools/make-icon.swift
tools/
  make-icon.swift  renders the icon to a 1024px PNG
Info.plist
build.sh
```
