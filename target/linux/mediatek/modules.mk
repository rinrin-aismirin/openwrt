define KernelPackage/ata-ahci-mtk
  TITLE:=Mediatek AHCI Serial ATA support
  KCONFIG:=CONFIG_AHCI_MTK
  FILES:= \
	$(LINUX_DIR)/drivers/ata/ahci_mtk.ko \
	$(LINUX_DIR)/drivers/ata/libahci_platform.ko
  AUTOLOAD:=$(call AutoLoad,40,libahci libahci_platform ahci_mtk,1)
  $(call AddDepends/ata)
  DEPENDS+=@(TARGET_mediatek_mt7622||TARGET_mediatek_mt7623)
endef

define KernelPackage/ata-ahci-mtk/description
 Mediatek AHCI Serial ATA host controllers
endef

$(eval $(call KernelPackage,ata-ahci-mtk))

define KernelPackage/btmtkuart
  SUBMENU:=Other modules
  TITLE:=MediaTek HCI UART driver
  DEPENDS:=@TARGET_mediatek_mt7622 +kmod-bluetooth +kmod-btmtk +mt7622bt-firmware \
	   +!LINUX_6_12:kmod-hci-uart
  KCONFIG:=CONFIG_BT_MTKUART
  FILES:= \
	$(LINUX_DIR)/drivers/bluetooth/btmtkuart.ko
  AUTOLOAD:=$(call AutoProbe,btmtkuart)
endef

$(eval $(call KernelPackage,btmtkuart))

define KernelPackage/iio-mt6577-auxadc
  TITLE:=Mediatek AUXADC driver
  DEPENDS:=@(TARGET_mediatek_mt7622||TARGET_mediatek_filogic)
  KCONFIG:=CONFIG_MEDIATEK_MT6577_AUXADC
  FILES:= \
	$(LINUX_DIR)/drivers/iio/adc/mt6577_auxadc.ko
  AUTOLOAD:=$(call AutoProbe,mt6577_auxadc)
  $(call AddDepends/iio)
endef
$(eval $(call KernelPackage,iio-mt6577-auxadc))


define KernelPackage/phy-mediatek-2p5g
  SUBMENU:=$(NETWORK_DEVICES_MENU)
  TITLE:=MediaTek 2.5G Ethernet PHY
  DEPENDS:=@TARGET_mediatek_filogic @!LINUX_6_12 +kmod-libphy
  KCONFIG:=CONFIG_MEDIATEK_2P5GE_PHY
  FILES:= \
   $(LINUX_DIR)/drivers/net/phy/mediatek/mtk-2p5ge.ko
  AUTOLOAD:=$(call AutoLoad,18,mtk-2p5ge,1)
endef

define KernelPackage/phy-mediatek-2p5g/description
  Kernel modules for 2.5G Ethernet PHY built-into the MediaTek MT7988
  and MT7987 SoCs.
endef

$(eval $(call KernelPackage,phy-mediatek-2p5g))

define KernelPackage/mt6990-modem
  SUBMENU:=Other modules
  TITLE:=MediaTek MT6990 modem (CCCI) drivers
  DEPENDS:=@TARGET_mediatek_mt6990
  KCONFIG:= \
	CONFIG_MTK_CCCI_DEVICES=y \
	CONFIG_MTK_ECCCI_DRIVER=m \
	CONFIG_MTK_ECCCI_CCIF=m \
	CONFIG_MTK_NET_CCMNI=m \
	CONFIG_MTK_TINYSYS_MEDMCU_SUPPORT=m \
	CONFIG_MTK_TINYSYS_MEDMCU_RV33_SUPPORT=m \
	CONFIG_MTK_MBOX=m \
	CONFIG_RPMSG=m \
	CONFIG_RPMSG_MTK=m \
	CONFIG_MTK_IPI=m
  FILES:= \
	$(LINUX_DIR)/drivers/soc/mediatek/mtk-mbox.ko \
	$(LINUX_DIR)/drivers/rpmsg/rpmsg_core.ko \
	$(LINUX_DIR)/drivers/rpmsg/mtk_rpmsg_mbox.ko \
	$(LINUX_DIR)/drivers/soc/mediatek/mtk_tinysys_ipi.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/ccci_util/ccci_util_lib.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/eccci/ccci_md_clk.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/eccci/ccci_rtc.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/eccci/ccci_auxadc.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/eccci/ccci_md_all.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/eccci/ccci_ccif.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/eccci/ccci_dpmaif.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/md_tx_power.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/ccmni/ccmni.ko \
	$(LINUX_DIR)/drivers/misc/mediatek/medmcu/rv33/medmcu.ko
endef

define KernelPackage/mt6990-modem/description
  Vendor CCCI, CCMNI, DPMAIF and MEDMCU drivers for the modem of the
  MediaTek MT6990 (T830). The modules are not loaded at boot; the modem
  service loads them when it is enabled. The modem also needs userspace
  from the stock firmware, which is not part of OpenWrt.
endef

$(eval $(call KernelPackage,mt6990-modem))
