echo ==== DQ10 FEL test boot: kernel + dtb + initramfs from RAM ====
setenv bootargs "console=tty1 console=ttyS0,115200 loglevel=7 rdinit=/init keep_bootcon"
fdt addr ${fdt_addr_r}
fdt resize 65536
booti ${kernel_addr_r} ${ramdisk_addr_r}:0x482d19 ${fdt_addr_r}
