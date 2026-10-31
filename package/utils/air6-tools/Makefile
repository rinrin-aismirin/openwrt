# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=air6-tools
PKG_RELEASE:=1

PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/air6-tools
  SECTION:=utils
  CATEGORY:=Base system
  DEPENDS:=@TARGET_mediatek_mt6990 \
	+@BUSYBOX_CONFIG_CMP \
	+@BUSYBOX_CONFIG_FLOCK \
	+@BUSYBOX_CONFIG_HEXDUMP \
	+@BUSYBOX_CONFIG_SHA256SUM \
	+fwtool +jsonfilter
  TITLE:=SoftBank Air 6 slot control, sysupgrade and stock slot backup
  PKGARCH:=all
endef

define Package/air6-tools/description
 A/B slot control for the SoftBank Air 6: marks the booted slot good at
 the end of start-up, switches slots when the LEVEL key is held at
 power-on, enters failsafe mode with the RESET or WPS key, writes
 sysupgrade images to the other slot (called from the mt6990
 /lib/upgrade/platform.sh), and backs up and restores a stock firmware
 slot.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/air6-tools/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/lib/air6 $(1)/lib/preinit $(1)/usr/sbin
	$(INSTALL_BIN) ./files/etc/init.d/air6-slot $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/etc/init.d/air6-slot-trial $(1)/etc/init.d/
	$(INSTALL_DATA) ./files/lib/air6/bootctrl.sh $(1)/lib/air6/
	$(INSTALL_DATA) ./files/lib/air6/upgrade.sh $(1)/lib/air6/
	$(INSTALL_DATA) ./files/lib/preinit/25_air6_slot_switch $(1)/lib/preinit/
	$(INSTALL_DATA) ./files/lib/preinit/29_air6_failsafe_keys $(1)/lib/preinit/
	$(INSTALL_DATA) ./files/lib/preinit/31_air6_failsafe_keys $(1)/lib/preinit/
	$(INSTALL_BIN) ./files/usr/sbin/air6-slot $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/usr/sbin/air6-stock $(1)/usr/sbin/
endef

$(eval $(call BuildPackage,air6-tools))
