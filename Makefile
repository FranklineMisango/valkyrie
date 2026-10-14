# Valkyrie Kernel Module Makefile
# Build: make -C /lib/modules/$(uname -r)/build M=$(PWD) modules
# Clean: make -C /lib/modules/$(uname -r)/build M=$(PWD) clean

obj-m := valkyrie.o
valkyrie-objs := src/valkyrie_main.o

ccflags-y := -I$(src)/include -O2 -Wall -Werror

KERNELDIR ?= /lib/modules/$(shell uname -r)/build
PWD       := $(shell pwd)

all:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) clean
	rm -f *.o *.ko *.mod.c Module.symvers Module.markers modules.order

install:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules_install
	depmod -a

.PHONY: all clean install