// SPDX-License-Identifier: GPL-2.0
// Compiled, never linked: build_modules.sh reads the "->name value" markers
// out of the assembly and compares them with the offsets the V1's own vendor
// modules use (v1/abi-offsets.txt).
#include <linux/module.h>
#include <linux/i2c.h>
#include <linux/platform_device.h>

#define OFF(name, val) asm volatile("\n.ascii \"->" #name " %0\"" : : "i" (val))

void morpthis_abi_probe(void);
void morpthis_abi_probe(void)
{
	OFF(i2c_client_dev, offsetof(struct i2c_client, dev));
	OFF(i2c_client_irq, offsetof(struct i2c_client, irq));
	OFF(i2c_client_platform_data, offsetof(struct i2c_client, dev) + offsetof(struct device, platform_data));
	OFF(i2c_client_driver_data, offsetof(struct i2c_client, dev) + offsetof(struct device, driver_data));
	OFF(platform_device_driver_data, offsetof(struct platform_device, dev) + offsetof(struct device, driver_data));
}

MODULE_LICENSE("GPL");
