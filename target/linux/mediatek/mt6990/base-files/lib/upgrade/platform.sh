# MT6990 sysupgrade. Only the SoftBank Air 6 is supported; other boards are refused. On the Air 6 sysupgrade writes
# the other A/B slot. The work is done in /lib/air6/upgrade.sh from the air6-tools package (sourced only when a
# platform hook runs, so that 'sysupgrade -b' and other users of /lib/upgrade see no side effects).

# Programs and files the Air 6 stage2 needs after the switch to the ramfs, beyond the upstream defaults. Missing files
# are skipped by install_file.
RAMFS_COPY_BIN="sha256sum flock head tr dirname"
RAMFS_COPY_DATA="/lib/air6/bootctrl.sh /lib/air6/upgrade.sh"

platform_check_image() {
	case "$(board_name)" in
	softbank,air6)
		# A missing library is a refusal that -F cannot override.
		[ -f /lib/air6/upgrade.sh ] || return 74
		. /lib/air6/upgrade.sh && au_check "$1"
		;;
	*)
		echo "Sysupgrade is not supported on this board."
		return 74
		;;
	esac
}

platform_pre_upgrade() {
	case "$(board_name)" in
	softbank,air6)
		. /lib/air6/upgrade.sh && au_pre_upgrade "$1"
		;;
	esac
}

platform_do_upgrade() {
	case "$(board_name)" in
	softbank,air6)
		. /lib/air6/upgrade.sh && au_do_upgrade "$1"
		;;
	*)
		echo "Sysupgrade is not supported on this board."
		return 1
		;;
	esac
}

# The Air 6 writes the config backup in platform_do_upgrade, before the new slot is activated.
platform_copy_config() {
	case "$(board_name)" in
	softbank,air6)
		return 0
		;;
	esac
}
