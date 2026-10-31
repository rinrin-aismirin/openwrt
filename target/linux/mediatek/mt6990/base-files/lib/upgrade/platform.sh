# SoftBank Air 6: sysupgrade writes the other A/B slot. The work is done in /lib/air6/upgrade.sh (sourced only when a
# platform hook runs, so that 'sysupgrade -b' and other users of /lib/upgrade see no side effects).

# Programs and files stage2 needs after the switch to the ramfs, beyond the upstream defaults.
RAMFS_COPY_BIN="sha256sum flock head tr dirname"
RAMFS_COPY_DATA="/lib/air6/bootctrl.sh /lib/air6/upgrade.sh"

platform_check_image() {
	# A missing library is a refusal that -F cannot override.
	[ -f /lib/air6/upgrade.sh ] || return 74
	. /lib/air6/upgrade.sh && au_check "$1"
}

platform_pre_upgrade() {
	. /lib/air6/upgrade.sh && au_pre_upgrade "$1"
}

platform_do_upgrade() {
	. /lib/air6/upgrade.sh && au_do_upgrade "$1"
}

# The config backup is written by platform_do_upgrade before the new slot is activated.
platform_copy_config() {
	return 0
}
