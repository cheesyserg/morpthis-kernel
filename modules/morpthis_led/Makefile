# Out-of-tree build of morpthis_led.ko. KDIR is a prepared kernel tree for
# the V1 kernel (see ../../scripts/build_modules.sh, which prepares one and builds this).
KDIR ?= /lib/modules/$(shell uname -r)/build
ARCH ?= mips
CROSS_COMPILE ?= mipsel-linux-gnu-

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean

.PHONY: all clean
