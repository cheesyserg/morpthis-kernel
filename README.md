# morpthis-kernel

The kernel side of Morpthis on the **TempoTec Variations V1** (Ingenic X1600):
the V1 kernel the firmware ships, the kit and configuration it is built from,
and the Morpthis kernel modules.

| Path | What it is |
| --- | --- |
| `v1/kernel.json` | the pin of the shipped kernel: Linux 4.4.94+, zram (LZ4, 24 MiB), its SHA-256, size, device tree hash, source commit, configuration hash |
| `v1/v1-kernel.sha256` | the same hash, in `sha256sum` form |
| `v1/configs/` | the V1 configuration: the fragments (`required`, `parity`, `stock-compat`, `zram`) and `tempotec_v1-final.config`, the full configuration of the shipped kernel (its hash is `config_sha256` in the pin) |
| `v1/board/` | the symbols the V1's vendor modules import (`modules-need.txt`) and export (`hiby-exports.txt`) |
| `v1/kit-patches.sha256`, `v1/kit-kernel-only.patch` | the hashes of the 18 kernel patches the V1 kernel was built with, and the kit change that builds the xImage alone |
| `kit/` | [hiby-custom-kernel](https://github.com/Jepl4r/hiby-custom-kernel) at `4c7d47e`, unchanged (GPL-2.0, see `kit/LICENSE` and `kit/README.md`) |
| `modules/morpthis_led/` | `morpthis_led.ko`, the status light's engine |
| `modules/axp2101/` | `axp2101.ko`, the AXP2101 PMIC driver, open, checked against the V1's vendor module, with the charger cable as a wake source |
| `scripts/build_modules.sh` | builds the modules |
| `scripts/build_kernel.sh` | rebuilds the kernel from source, and the modules against that tree |

## The kernel

The firmware uses the prebuilt `v1-zram-xImage` from the `build-inputs`
release of [Starnished66/compas-firmware](https://github.com/Starnished66/compas-firmware),
pinned by `v1/kernel.json`. It is the stock V1 kernel's version (`4.4.94+`,
so every vendor module loads unchanged) rebuilt from Ingenic's SDK with the
kit's patches, with compressed RAM swap added and the stock device tree kept
byte for byte. The packer in `morpthis-player` (`morpthis-packer/`) checks the
hash, the size bound, the uImage CRCs and the device tree against the stock
kernel of the image it repacks before it replaces anything, and installs the
zram hook (`S31morpthis_zram`) with it.

As its pin says, the kernel was statically checked rather than validated on
hardware before it was published; Morpthis ships it on that basis.

### Rebuilding it

Ingenic's SDK is not redistributable, so it is not here. With it:

```sh
scripts/build_kernel.sh --sdk ingenic-linux-kernel4.4.94-x1600-v6.0-20240606.tar.bz2 --stock v1.upt
```

This runs the kit's own Docker build for a `tempotec_v1` board (device tree
taken from your stock firmware and checked against the pin), builds the
modules against the same tree, and compares the resulting configuration with
`v1/configs/tempotec_v1-final.config`. The xImage is not byte-identical to the
pinned one (the build stamps a host and a date, and the published image was
recompressed with zopfli), so the firmware keeps shipping the pinned image.

## morpthis_led.ko

The V1's status light is an SGM31324 RGB controller on I2C bus 0 at `0x30`.
The player used to drive it from userspace over `/dev/i2c-0`; this module is
that engine in the kernel. Same registers, same level ladder, same effects
(cross-fade, quadratic fade-out, blink, hardware breathing), and on top of it:

- fades are kernel work on a 10 ms step, unaffected by the interface thread;
- a register shadow, so a step that does not change a register does not send it;
- the blink wakes no process;
- the light goes out at any reboot or power-off, and the shadow is dropped
  across a suspend.

Interface, under `/sys/devices/platform/morpthis-led/`:

| Node | |
| --- | --- |
| `render` (w) | `MODE R G B PERIOD DUTY FADE TRANSITION_MS STEP_MS` -- MODE 0 steady, 1 breathing, 2 blink, 3 off; levels 0-79 |
| `busy` (r) | 1 while a fade runs |
| `wait` (r) | waits up to 50 ms for the fade to end, then reads as `busy` |
| `regs` (r) | the register shadow |
| `resync` (w) | forget the shadow |

```sh
echo "0 0 79 40 0 0 0 500 10" > /sys/devices/platform/morpthis-led/render   # fade to teal
echo "3 0 0 0 0 0 0 500 10"   > /sys/devices/platform/morpthis-led/render   # fade out
```

The player loads it itself (`/module_driver/morpthis_led.ko`), after unloading
the vendor's `leds_sgm31324_add`, and falls back to its own I2C path when the
module is missing, refuses to load, or a previous boot never finished loading
it (`/usr/data/.morpthis_led_loading`). `[led] kernel_driver = 0` in
`device_config.ini` keeps it on the I2C path.

### Building it

```sh
scripts/build_modules.sh out/
```

Needs a MIPS cross compiler (`mipsel-linux-gnu-gcc`, e.g. Ubuntu's
`gcc-10-mipsel-linux-gnu`; `CROSS_COMPILE` overrides). Without `KDIR` it builds
against mainline linux-4.4.94 configured with the V1's own configuration --
the machine is the one thing mainline lacks. `MACH_XILFPGA` stands in for it
(little-endian MIPS32r2 that, like the V1, requires GPIOLIB), every option the
V1 has on and mainline defines is forced on, and the structure offsets are
compared with the ones the V1's own vendor modules were compiled with
(`v1/abi-offsets.txt`, read from the stock `axp2101.ko`). The first stand-in,
Malta, dropped `GPIOLIB` (the gpiolib calls compiled to stubs) and `PINCTRL`
(`struct device` four bytes short, so `client->irq` was read from the wrong
place): the PMIC driver came up without its interrupt and the charger cell
never started. Both are now build failures instead. The result must carry the V1
kernel's vermagic, `4.4.94+ preempt mod_unload MIPS32_R2 32BIT`, or the
script fails. Every symbol the module imports is a core kernel export present
in the shipped image. With `KDIR` pointing at the real tree (what
`build_kernel.sh` leaves behind) it builds against that instead.

## axp2101.ko: the PMIC, open, and the cable as a wake source

The V1's power IC is an X-Powers AXP2101 on I2C bus 0, its interrupt on PB23.
HiBy's driver for it is the closed `axp2101.ko` in `/module_driver` (its own
modinfo says `license=GPL v2`; it is Ingenic's port of mainline `axp20x`).
That module follows the cable by **polling**: it never requests one of the
PMIC's interrupts, so regmap-irq keeps all of them masked inside the PMIC,
PB23 never moves, and nothing can wake a suspended SoC when a charger is
plugged in. The only wake sources the stock firmware arms are the power key
(PC31) and PC28, through `keyboard_gpio_add.ko` (`wakeup=y` in its script).
No userspace switch can change that, which is why wake on plug did not work.

`modules/axp2101/axp2101.c` is the open driver from the kit
(`kit/modules/axp2101`, written for the R1 and R3 Pro II), checked against the
V1's binary:

| | V1 vendor `axp2101.ko` | `modules/axp2101` |
| --- | --- | --- |
| exports | `axp20x_match_device`, `axp20x_device_probe`, `axp20x_device_remove`, `charger_plugged` | the same |
| depends | `utils` | `utils` |
| parameters | `i2c_bus_num`, `pmu_int_gpio`, `charge_voltage_limit`, `charge_term_current`, `dcdc3_always_pwmmode`, the 16 regulator strings | the same, plus `plug_wake` |
| interrupt map | 24 entries, REG48h-4Ah bit by bit | the same |
| charger cell resources | 20 named interrupts, `usb in` = 15 | the same, same order |
| fuel-gauge model | 128 bytes | byte-identical |
| AXP2101 register writes (probe, init, suspend, resume, power off) | | the same registers |
| other chips' code (AXP152/22x/803/806/809/858/2202/2585 tables, drivevbus, DCDC frequency, DT parsing) | present, never runs for the AXP2101 (variant 8) | absent |

The V1's binary is not the R1's: the R1 build has since gained a SoC-ID rule
for DCDC4, an OVP pin and OTG state. The V1 build has none of them, and
neither does this driver.

The one change is the wake. The driver requests `usb in` (REG41h bit 7, VBUS
insert), which unmasks it in the PMIC, makes the charger cell a wakeup device
(`/sys/class/power_supply/usb/device/power/wakeup`, on by default) and arms
the interrupt for every suspend. Waking a regmap-irq child arms the parent,
PB23, the same way the power key's pin is armed. The parent is requested
level-low, which is how the line actually behaves; the vendor driver passed no
trigger type, which only worked because the line never fired. The interrupt
also wakes the monitor thread, so the `usb` supply follows a plug at once
instead of on the next one-second poll. `plug_wake=0` turns the wake off.

The firmware packer installs it as `module_driver/axp2101.ko`, keeps the
vendor's as `axp2101_vendor.ko`, and adds one line to `axp2101.sh` that loads
the vendor module with the same parameters if the open one is not loaded
afterwards. `MORPTHIS_VENDOR_AXP2101=1` keeps the vendor module.

Like the kernel, it has been checked statically -- every import resolves
against the shipped kernel and the V1's `utils.ko`, vermagic matches -- not
yet on hardware.

## Licence

GPL-3.0 for this repository (`LICENSE`); `kit/` is GPL-2.0 (`kit/LICENSE`),
and `morpthis_led.c` is GPL-2.0, as kernel code. The V1 configuration, the
symbol lists, the kit patch and the pin come from
[Compás firmware](https://github.com/Starnished66/compas-firmware)
(`firmware/kernel/`, GPL-3.0).
