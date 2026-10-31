# SPDX-License-Identifier: GPL-2.0-only
#
# MediaTek MT6990 / T830 devices

# SoftBank Air 6 (A775). The board boots an MTK-signed Android boot v2 image (kernel + DTB) from boot_a/boot_b
# and a squashfs rootfs from rootfs_a/rootfs_b. This recipe stops at the unsigned parts; packing the boot image
# and signing it are done outside the build.
define Device/softbank_air6
  DEVICE_VENDOR := SoftBank
  DEVICE_MODEL := Air 6
  DEVICE_VARIANT := A775
  SOC := mt6990
  KERNEL_LOADADDR := 0x80080000
  KERNEL_ENTRY := 0x80080000
  KERNEL := kernel-bin
  DEVICE_DTS := mt6990-softbank-air6
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := air6-tools kmod-mt7996e wpad-mbedtls kmod-usb-mtu3 kmod-usb-storage \
	kmod-fs-vfat kmod-nls-cp437 kmod-nls-iso8859-1 kmod-nls-utf8
  FILESYSTEMS := squashfs
  IMAGES := kernel.bin dtb rootfs.img
  IMAGE/kernel.bin := append-kernel
  IMAGE/dtb := append-dtb
  IMAGE/rootfs.img := append-rootfs
endef
TARGET_DEVICES += softbank_air6
