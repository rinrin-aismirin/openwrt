# sysupgrade of the SoftBank Air 6: write the other A/B slot. Called from /lib/upgrade/platform.sh:
#   au_check IMAGE        platform_check_image (sysupgrade CLI and procd); no change on the unit; 0 or 74
#   au_pre_upgrade IMAGE  platform_pre_upgrade (stage2, services already stopped, before the ramfs switch): admission
#   au_do_upgrade IMAGE   platform_do_upgrade (stage2, in ramfs): invalidate, write, read back, config, activate
#
# Package (an upstream sysupgrade tar followed by fwtool metadata): exactly the directory sysupgrade-softbank_air6/
# and the regular files CONTROL, kernel (the signed boot image, 32 MiB) and root (the squashfs, its size rounded up to
# 4 KiB, no further padding), in this order. CONTROL: key=value lines in this fixed order, parsed and never sourced:
#   BOARD=softbank_air6, format=air6-sysupgrade/1, kernel_size, kernel_sha256, root_size, root_sha256,
#   squashfs_bytes_used, trial=0|1, modem_version=<V.._.._P.. or empty>, fork=<40 hex>, kit=<40 hex or none>
# Metadata: supported_devices has softbank,air6; compat_version 1.0. Every refusal is 74 (not forceable).
#
# Admission crosses the stage2 boundary through a private run directory (copies of the image and the config, the
# extracted kernel and root, and a complete context file); the update reservation of bootctrl.sh marks the run.
# Terminal states of stage2 (the procd upgraded process reboots as soon as stage2 exits, whatever its status):
#   refused  nothing written, the boot control record read back with the booted slot next and successful: reboot
#   failed   a partition or config write failed, the record read back with the booted slot next and successful: reboot
#   written  all writes, the config and the activation read back: reboot into the new slot (trial of the preloader)
#   halted   the record is not certain (unreadable, invalid, a write with an unknown outcome, next slot not the
#            booted one): stage2 does not exit; it reports on the console and runs a shell there, the power LED
#            blinks red. Without a serial console this equals a power cycle with the same record.
# INT, TERM, HUP and PIPE are ignored in both stage2 hooks, so a signal cannot end stage2 (and with it, trigger the
# reboot) between a boot control write and the decision on its outcome.
# Every step goes to the console and, as a parse-only record, to the pstore pmsg device; air6-slot boot-done keeps
# the last one in /etc/air6-slot/last-upgrade. A missing record means "result unknown".
#
# Sourcing this file has no side effects. Overrides for host tests only: AU_SYS, AU_DEV, AU_PROC, AU_TMP, AU_STOCK,
# AU_PMSG, AU_CONSOLE, AU_LEDS, AU_FWTOOL, AU_JSONFILTER, AU_HALT_CMD, AU_BCLIB, AU_KERNEL_SIZE, AU_MIN_OVERLAY (and
# those of bootctrl.sh).

. "${AU_BCLIB:-/lib/air6/bootctrl.sh}"

AU_BOARD=softbank_air6
AU_DIR=sysupgrade-softbank_air6
AU_FORMAT=air6-sysupgrade/1
AU_KEYS="BOARD format kernel_size kernel_sha256 root_size root_sha256 squashfs_bytes_used trial modem_version fork kit"
# Sizes: the boot image as installed (32 MiB) and the smallest overlay left behind the squashfs (16 MiB).
: "${AU_KERNEL_SIZE:=33554432}"
: "${AU_MIN_OVERLAY:=16777216}"
AU_CONTROL_MAX=4096
AU_REC=air6-upgrade/1
AU_VER_RE='MOLY[A-Z0-9_]*_V[0-9]*_[0-9]*_P[0-9]*'
: "${AU_SYS:=/sys}"
: "${AU_DEV:=/dev}"
: "${AU_PROC:=/proc}"
: "${AU_TMP:=/tmp}"
: "${AU_STOCK:=/usr/sbin/air6-stock}"
: "${AU_PMSG:=/dev/pmsg0}"
: "${AU_CONSOLE:=/dev/console}"
: "${AU_LEDS:=/sys/class/leds}"
: "${AU_FWTOOL:=fwtool}"
: "${AU_JSONFILTER:=jsonfilter}"
AU_RUNS="$AU_TMP/air6-upgrade"

# Messages -------------------------------------------------------------------------------------------------------

AU_TOKEN=- AU_STAGE2=
au_say() { echo "air6-upgrade: $*" >&2; }
# au_rec KEY=VALUE...: one record line on the console and in pmsg (best effort, never fails the caller).
au_rec() {
	local l
	l="$(echo "$AU_REC token=$AU_TOKEN $*" | tr -d '\r' | cut -c1-400)"
	echo "$l" >&2
	[ -n "$AU_STAGE2" ] && [ -w "$AU_PMSG" ] && [ ! -d "$AU_PMSG" ] && echo "$l" >> "$AU_PMSG" 2>/dev/null
	return 0
}
au_err() { au_say "error: $*"; au_rec "msg=error" "text=$(echo "$*" | tr ' =' '_:')"; }

au_is_hex() { case "$1" in *[!0-9a-f]*) return 1 ;; esac; [ "${#1}" = "$2" ]; }
au_sha() { local h; h="$(sha256sum "$1" 2>/dev/null)" || return 5; h="${h%% *}"; au_is_hex "$h" 64 || return 5; echo "$h"; }
au_boot_id() { cat "$AU_PROC/sys/kernel/random/boot_id" 2>/dev/null; }
au_rand() { head -c 16 /dev/urandom 2>/dev/null | hexdump -v -e '16/1 "%02x"'; }
au_roundup() { echo $(( ($1 + $2 - 1) / $2 * $2 )); }

# Partitions -----------------------------------------------------------------------------------------------------

# au_part NAME VAR: VAR_dev and VAR_size (bytes) of the single eMMC partition named NAME.
au_part() {
	local u n s= c=0 z
	for u in "$AU_SYS"/block/mmcblk0/mmcblk0p*/uevent; do
		[ -f "$u" ] || continue
		n="$(sed -n 's/^PARTNAME=//p' "$u")"
		[ "$n" = "$1" ] && { s="${u%/uevent}"; c=$((c + 1)); }
	done
	[ "$c" = 1 ] || { au_say "error: partition $1 not found (or not unique)"; return 5; }
	z="$(cat "$s/size" 2>/dev/null)"
	case "$z" in ''|*[!0-9]*) au_say "error: size of partition $1 not readable"; return 5 ;; esac
	eval "$2_dev=\$AU_DEV/\${s##*/}; $2_size=\$((z * 512))"
	eval "[ -e \"\$$2_dev\" ]" || { au_say "error: device of partition $1 missing"; return 5; }
}

# Package --------------------------------------------------------------------------------------------------------

# au_control_parse FILE: FILE is a well-formed CONTROL; sets C_<key> for every key.
au_control_parse() {
	local k v n=0 line
	[ "$(wc -c < "$1")" -le "$AU_CONTROL_MAX" ] || { au_say "error: CONTROL too large"; return 1; }
	[ "$(wc -l < "$1")" = "$(echo $AU_KEYS | wc -w)" ] || { au_say "error: CONTROL must have exactly the keys $AU_KEYS"; return 1; }
	for k in $AU_KEYS; do
		n=$((n + 1))
		line="$(sed -n "${n}p" "$1")"
		[ "${line%%=*}" = "$k" ] || { au_say "error: CONTROL line $n is not $k="; return 1; }
		v="${line#*=}"
		case "$k" in
		BOARD) [ "$v" = "$AU_BOARD" ] ;;
		format) [ "$v" = "$AU_FORMAT" ] ;;
		kernel_size|root_size|squashfs_bytes_used) case "$v" in ''|0*|*[!0-9]*) false ;; *) [ "${#v}" -le 10 ] ;; esac ;;
		kernel_sha256|root_sha256) au_is_hex "$v" 64 ;;
		trial) case "$v" in 0|1) true ;; *) false ;; esac ;;
		modem_version) case "$v" in '') true ;; V[0-9]*_[0-9]*_P[0-9]*) case "$v" in *[!0-9A-Z_]*) false ;; *) [ "${#v}" -le 32 ] ;; esac ;; *) false ;; esac ;;
		fork) au_is_hex "$v" 40 ;;
		kit) [ "$v" = none ] || au_is_hex "$v" 40 ;;
		esac || { au_say "error: CONTROL value of $k is not valid"; return 1; }
		eval "C_$k=\$v"
	done
}

# au_members IMAGE: the tar holds exactly the directory and the three regular files, in this order.
au_members() {
	local l
	l="$(tar tvf "$1" 2>/dev/null | awk '
		NF != 6 { bad = 1 }
		{ t = substr($1, 1, 1); printf "%s %s %s\n", t, $3, $6 }
		END { exit bad }')" || { au_say "error: the package is not a plain tar (or has unexpected members)"; return 1; }
	echo "$l" | awk -v d="$AU_DIR" '
		NR == 1 { ok = ($1 == "d" && $3 == d "/") }
		NR == 2 { ok = ok && ($1 == "-" && $3 == d "/CONTROL") }
		NR == 3 { ok = ok && ($1 == "-" && $3 == d "/kernel") }
		NR == 4 { ok = ok && ($1 == "-" && $3 == d "/root") }
		END { exit !(ok && NR == 4) }' ||
		{ au_say "error: the package must hold exactly $AU_DIR/, CONTROL, kernel and root, in this order"; return 1; }
	M_kernel_size="$(echo "$l" | awk 'NR == 3 { print $2 }')"
	M_root_size="$(echo "$l" | awk 'NR == 4 { print $2 }')"
}

# au_metadata IMAGE: fwtool metadata present, for this board, compat_version 1.0.
au_metadata() {
	local m dev ver
	m="$(mktemp "$AU_TMP/air6-upgrade-meta.XXXXXX")" || { au_say "error: no temporary file"; return 1; }
	if ! "$AU_FWTOOL" -q -i "$m" "$1" 2>/dev/null; then
		rm -f "$m"; au_say "error: the package has no image metadata"; return 1
	fi
	dev="$("$AU_JSONFILTER" -i "$m" -e '@.supported_devices[*]' 2>/dev/null)"
	ver="$("$AU_JSONFILTER" -i "$m" -e '@.compat_version' 2>/dev/null)"
	rm -f "$m"
	echo "$dev" | grep -qx 'softbank,air6' || { au_say "error: the package is not for softbank,air6 (supported_devices: $(echo $dev))"; return 1; }
	# Only 1.0: for other versions upstream reads new_supported_devices and compares the unit's compat_version, which
	# this check does not repeat; refusing here keeps every metadata failure non-forceable (74).
	[ "$ver" = 1.0 ] || { au_say "error: the package's compat_version '$ver' is not 1.0"; return 1; }
}

# au_le64 FILE OFFSET: the little-endian 64-bit value at OFFSET.
au_le64() {
	local h
	h="$(dd if="$1" bs=1 skip="$2" count=8 2>/dev/null | hexdump -v -e '8/1 "%02x"')"
	au_is_hex "$h" 16 || return 1
	echo $((0x$(echo "$h" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\8\7\6\5\4\3\2\1/')))
}

# au_payload_check KERNEL ROOT ROOTFS_PART_SIZE: the extracted files match CONTROL; sets AU_OFFSET.
au_payload_check() {
	local h bu
	[ "$C_kernel_size" = "$AU_KERNEL_SIZE" ] || { au_say "error: kernel_size must be $AU_KERNEL_SIZE"; return 1; }
	[ "$(wc -c < "$1")" = "$C_kernel_size" ] && [ "$(wc -c < "$2")" = "$C_root_size" ] ||
		{ au_say "error: kernel or root has another size than in CONTROL"; return 1; }
	h="$(au_sha "$1")" && [ "$h" = "$C_kernel_sha256" ] || { au_say "error: kernel does not match kernel_sha256"; return 1; }
	h="$(au_sha "$2")" && [ "$h" = "$C_root_sha256" ] || { au_say "error: root does not match root_sha256"; return 1; }
	[ "$(dd if="$1" bs=8 count=1 2>/dev/null)" = 'ANDROID!' ] || { au_say "error: kernel is not an Android boot image"; return 1; }
	[ "$(dd if="$2" bs=4 count=1 2>/dev/null)" = hsqs ] || { au_say "error: root is not a squashfs"; return 1; }
	bu="$(au_le64 "$2" 40)" || { au_say "error: squashfs superblock not readable"; return 1; }
	[ "$bu" = "$C_squashfs_bytes_used" ] || { au_say "error: squashfs bytes_used $bu differs from CONTROL"; return 1; }
	[ "$bu" -gt 96 ] && [ "$(au_roundup "$bu" 4096)" = "$C_root_size" ] ||
		{ au_say "error: root must be the squashfs rounded up to 4 KiB, without other padding"; return 1; }
	AU_OFFSET="$(au_roundup "$bu" 65536)"
	[ $((AU_OFFSET + AU_MIN_OVERLAY)) -le "$3" ] ||
		{ au_say "error: the squashfs leaves less than $((AU_MIN_OVERLAY / 1048576)) MiB for the overlay"; return 1; }
}

# au_image IMAGE OUTDIR: metadata, members, CONTROL, and the payload extracted to OUTDIR/{CONTROL,kernel,root} and
# checked. Needs AU_TGT set (for the partition sizes).
au_image() {
	au_metadata "$1" && au_members "$1" || return 1
	tar xOf "$1" "$AU_DIR/CONTROL" > "$2/CONTROL" 2>/dev/null || { au_say "error: CONTROL not readable"; return 1; }
	au_control_parse "$2/CONTROL" || return 1
	[ "$M_kernel_size" = "$C_kernel_size" ] && [ "$M_root_size" = "$C_root_size" ] ||
		{ au_say "error: member sizes differ from CONTROL"; return 1; }
	au_part "boot_$AU_TGT" PB && au_part "rootfs_$AU_TGT" PR || return 1
	[ "$C_kernel_size" -le "$PB_size" ] || { au_say "error: kernel larger than boot_$AU_TGT"; return 1; }
	tar xOf "$1" "$AU_DIR/kernel" > "$2/kernel" 2>/dev/null && tar xOf "$1" "$AU_DIR/root" > "$2/root" 2>/dev/null ||
		{ au_say "error: cannot extract the payload (space in $AU_TMP?)"; return 1; }
	au_payload_check "$2/kernel" "$2/root" "$PR_size"
}

# Unit state -----------------------------------------------------------------------------------------------------

# au_state [TOKEN]: record valid, booted slot next and successful; no update reservation (or the one of TOKEN).
au_state() {
	local r m
	r="$(bc_read)" || return 1
	bc_valid "$r" || { au_say "error: unexpected boot control record $r"; return 1; }
	[ "$(bc_next "$r")" = "$BC_CUR" ] ||
		{ au_say "error: the next boot slot is $(bc_next "$r"), not the booted slot $BC_CUR (bootctrl $r)"; return 1; }
	[ "$(bc_get "$r" "$BC_CUR" success)" = 01 ] ||
		{ au_say "error: the booted slot $BC_CUR is not marked successful yet (bootctrl $r); finish or commit it first"; return 1; }
	# The other slot must not be the partition the running system uses as its root.
	m="$(bc_root_check)"
	case $? in
	0) ;;
	1) au_say "error: $m; the running image boots the wrong rootfs, so the other slot may be in use"; return 1 ;;
	*) au_say "error: cannot tell which partition the root file system is on"; return 1 ;;
	esac
	if [ -n "$1" ]; then
		bc_reservation_owned "$1" || { au_say "error: the update reservation is not this run's ($(bc_reservation || echo none))"; return 1; }
	else
		bc_reservation >/dev/null && { au_say "error: an update of the other slot is in progress ($(bc_reservation))"; return 1; }
	fi
	AU_RECORD="$r"
}

# au_target_class: AU_CLASS = stock, openwrt or unfinished for rootfs_$AU_TGT; 1 when it cannot be decided.
au_target_class() {
	local m mnt rc=0 r
	AU_CLASS=
	au_part "rootfs_$AU_TGT" PR || return 1
	m="$(dd if="$PR_dev" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"')"
	au_is_hex "$m" 8 || { au_say "error: rootfs_$AU_TGT not readable; cannot tell what slot $AU_TGT holds"; return 1; }
	if [ "$m" != 68737173 ]; then
		r="$(bc_read)" || return 1
		if [ "$(bc_get "$r" "$AU_TGT" success)" = 00 ]; then
			AU_CLASS=unfinished
			return 0
		fi
		au_say "error: rootfs_$AU_TGT holds no squashfs, but slot $AU_TGT is marked successful; cannot tell what it holds"
		return 1
	fi
	mnt="$(mktemp -d "$AU_TMP/air6-upgrade-mnt.XXXXXX")" || { au_say "error: no mount point"; return 1; }
	if ! mount -t squashfs -o ro "$PR_dev" "$mnt" 2>/dev/null; then
		rmdir "$mnt"
		au_say "error: rootfs_$AU_TGT has a squashfs magic but cannot be mounted; cannot tell what slot $AU_TGT holds"
		return 1
	fi
	if [ -f "$mnt/lib/upgrade/bootctrl.sh" ] && [ ! -L "$mnt/lib/upgrade/bootctrl.sh" ]; then AU_CLASS=stock
	elif [ -f "$mnt/usr/sbin/air6-slot" ] || [ -f "$mnt/usr/sbin/air6-abguard" ]; then AU_CLASS=openwrt
	else au_say "error: slot $AU_TGT holds neither the stock firmware nor OpenWrt for the Air 6"; rc=1
	fi
	umount "$mnt" 2>/dev/null || { au_say "error: cannot unmount $mnt"; return 1; }
	rmdir "$mnt"
	return "$rc"
}

# au_target: the content gate (stock: confirmed backup and verify) and the modem version.
au_target() {
	local v
	au_target_class || return 1
	if [ "$AU_CLASS" = stock ]; then
		au_say "slot $AU_TGT holds the stock firmware; checking its confirmed backup"
		"$AU_STOCK" verify "$AU_TGT" >&2 ||
			{ au_say "error: 'air6-stock verify $AU_TGT' failed: back up the stock slot first ('device.sh stock-backup')"; return 1; }
	fi
	if [ -n "$C_modem_version" ]; then
		au_part "md1img_$AU_TGT" PM || return 1
		v="$(head -c 262144 "$PM_dev" 2>/dev/null | grep -a -o -m1 "$AU_VER_RE" | head -n 1)"
		case "$v" in *"_$C_modem_version") ;; *)
			au_say "error: the image's modem programs are $C_modem_version, md1img_$AU_TGT is ${v:-unknown}"; return 1 ;;
		esac
	fi
}

# platform_check_image -------------------------------------------------------------------------------------------

au_check() {
	local w rc=0
	bc_init || return 74
	AU_TGT="$BC_OTHER"
	w="$(mktemp -d "$AU_TMP/air6-upgrade-check.XXXXXX")" || { au_say "error: no temporary directory"; return 74; }
	{ au_image "$1" "$w" && au_state "" && au_target; } || rc=74
	rm -rf "$w"
	[ "$rc" = 0 ] && au_say "package for slot $AU_TGT accepted (offset of the overlay $AU_OFFSET, trial=$C_trial)"
	return "$rc"
}

# Admission (platform_pre_upgrade) -------------------------------------------------------------------------------

# au_config FILE: a config backup fstools restores (starts 1f 8b 08 00, complete gzip and tar), fitting the overlay.
au_config() {
	local h s
	[ -f "$1" ] && [ ! -L "$1" ] || { au_say "error: the config backup is not a regular file"; return 1; }
	h="$(dd if="$1" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"')"
	[ "$h" = 1f8b0800 ] || { au_say "error: the config backup does not start with 1f 8b 08 00 (fstools would not restore it)"; return 1; }
	gzip -t "$1" 2>/dev/null && tar tzf "$1" >/dev/null 2>&1 || { au_say "error: the config backup is not a complete tar.gz"; return 1; }
	s="$(wc -c < "$1")"
	[ $((AU_OFFSET + s)) -le "$PR_size" ] || { au_say "error: the config backup does not fit behind the squashfs"; return 1; }
	AU_CFG_SIZE="$s"
}

au_ctx_put() {
	{
		echo "token=$AU_TOKEN"
		echo "boot_id=$(au_boot_id)"
		echo "booted=$BC_CUR"
		echo "target=$AU_TGT"
		echo "class=$AU_CLASS"
		echo "record=$AU_RECORD"
		echo "image_sha256=$AU_IMG_SHA"
		echo "kernel_size=$C_kernel_size"
		echo "kernel_sha256=$C_kernel_sha256"
		echo "root_size=$C_root_size"
		echo "root_sha256=$C_root_sha256"
		echo "offset=$AU_OFFSET"
		echo "config=$AU_CFG"
		echo "config_size=$AU_CFG_SIZE"
		echo "config_sha256=$AU_CFG_SHA"
		echo "trial=$C_trial"
		echo "complete=1"
	} > "$AU_RUN/context.tmp" && mv "$AU_RUN/context.tmp" "$AU_RUN/context"
}

# au_state_locked TOKEN: (boot control lock held) au_state for TOKEN, then print the record checked.
au_state_locked() {
	au_state "$1" || return 1
	echo "@rec $AU_RECORD"
}

au_reserve_locked() {
	bc_reservation >/dev/null && { au_say "error: an update of the other slot is in progress ($(bc_reservation))"; return 4; }
	bc_reserve "$1" "$2"
}

au_admit() {
	local free need cfg=0
	[ "${UPGRADE_OPT_USE_CURR_PART:-0}" = 1 ] && { au_err "sysupgrade -s (stay on the current slot) is not supported on the Air 6"; return 1; }
	[ -f "$1" ] || { au_err "image $1 missing"; return 1; }
	bc_init || { au_err "boot control not readable"; return 1; }
	AU_TGT="$BC_OTHER"
	au_is_hex "$AU_TOKEN" 32 || { au_err "no random token"; return 1; }
	free="$(df -Pk "$AU_TMP" 2>/dev/null | awk 'NR == 2 { print $4 }')"
	[ -n "$UPGRADE_BACKUP" ] && { cfg="$(wc -c < "$UPGRADE_BACKUP" 2>/dev/null)" || { au_err "config backup $UPGRADE_BACKUP not readable"; return 1; }; }
	# The image copy, the extracted kernel and root (about the image size again), the config copy, a margin.
	need=$(( ($(wc -c < "$1") * 2 + cfg) / 1024 + 16384 ))
	case "$free" in ''|*[!0-9]*) au_err "free space of $AU_TMP unknown"; return 1 ;; esac
	[ "$free" -ge "$need" ] || { au_err "not enough space in $AU_TMP: $free KiB free, $need KiB needed"; return 1; }
	bc_with_lock au_reserve_locked "$AU_TOKEN" "boot_id=$(au_boot_id) pid=$$ target=$AU_TGT phase=sysupgrade" ||
		{ au_err "update reservation not taken"; return 1; }
	AU_RESERVED=1
	au_rec "phase=admission" "booted=$BC_CUR" "target=$AU_TGT"
	cp "$1" "$AU_RUN/image" || { au_err "cannot copy the image"; return 1; }
	AU_IMG_SHA="$(au_sha "$AU_RUN/image")" || { au_err "cannot hash the image copy"; return 1; }
	AU_CFG=0 AU_CFG_SIZE=0 AU_CFG_SHA=-
	if [ -n "$UPGRADE_BACKUP" ]; then
		cp "$UPGRADE_BACKUP" "$AU_RUN/config.tgz" || { au_err "cannot copy the config backup"; return 1; }
	fi
	au_image "$AU_RUN/image" "$AU_RUN" || { au_err "the image copy failed its check"; return 1; }
	AU_RECORD="$(bc_with_lock au_state_locked "$AU_TOKEN" | sed -n 's/^@rec //p')"
	[ -n "$AU_RECORD" ] || { au_err "the unit state changed since the check"; return 1; }
	au_target || { au_err "the target slot failed its check"; return 1; }
	if [ -n "$UPGRADE_BACKUP" ]; then
		au_config "$AU_RUN/config.tgz" || { au_err "the config backup failed its check"; return 1; }
		AU_CFG=1
		AU_CFG_SHA="$(au_sha "$AU_RUN/config.tgz")" || { au_err "cannot hash the config backup"; return 1; }
	fi
	au_ctx_put || { au_err "cannot store the run context"; return 1; }
	au_rec "phase=admitted" "class=$AU_CLASS" "image=$AU_IMG_SHA" "config=$AU_CFG" "record=$AU_RECORD"
}

au_pre_upgrade() {
	AU_STAGE2=1 AU_RESERVED=
	# Stage2 must not end on a signal: upgraded reboots as soon as it exits. Children inherit the ignored signals.
	trap '' INT TERM HUP PIPE
	# A run of an earlier sysupgrade in this boot is never taken for this one.
	rm -f "$AU_RUNS/current"
	[ ! -e "$AU_RUNS/current" ] || { au_err "cannot remove $AU_RUNS/current"; return 0; }
	mkdir -p "$AU_RUNS" && chmod 700 "$AU_RUNS" || { au_err "cannot create $AU_RUNS"; return 0; }
	AU_RUN="$(mktemp -d "$AU_RUNS/run.XXXXXX")" || { au_err "cannot create a run directory"; return 0; }
	# The token names this run in every record line, also when it is not admitted.
	AU_TOKEN="$(au_rand)"; au_is_hex "$AU_TOKEN" 32 || AU_TOKEN=-
	echo "$AU_TOKEN" > "$AU_RUN/token" && [ "$(cat "$AU_RUN/token")" = "$AU_TOKEN" ] &&
		echo "$AU_RUN" > "$AU_RUNS/current" && [ "$(cat "$AU_RUNS/current")" = "$AU_RUN" ] ||
		{ rm -f "$AU_RUNS/current"; au_err "cannot store the run token in $AU_RUN"; return 0; }
	au_rec "phase=begin" "boot_id=$(au_boot_id)"
	if ! au_admit "$1"; then
		echo "not admitted" > "$AU_RUN/not-admitted"
		rm -f "$AU_RUN/context"
		if [ -n "$AU_RESERVED" ]; then
			bc_with_lock bc_release "$AU_TOKEN" >/dev/null 2>&1 || au_err "own update reservation not removed"
		fi
		au_rec "phase=admission" "result=not-admitted"
	fi
	return 0
}

# Writing (platform_do_upgrade) ----------------------------------------------------------------------------------

AU_SURE=1 AU_LAST= AU_PHASE=

# au_ctx KEY: a value of the run context.
au_ctx() { sed -n "s/^$1=//p" "$AU_RUN/context" | head -n 1; }

au_load() {
	local k r
	[ -f "$AU_RUNS/current" ] || return 1
	r="$(cat "$AU_RUNS/current")"
	case "$r" in "$AU_RUNS"/run.??????) AU_RUN="$r" ;; *) return 1 ;; esac
	[ -f "$AU_RUN/context" ] && [ ! -e "$AU_RUN/not-admitted" ] || return 1
	[ "$(tail -n 1 "$AU_RUN/context")" = complete=1 ] && [ "$(wc -l < "$AU_RUN/context")" = 17 ] || return 1
	for k in token boot_id booted target class record image_sha256 kernel_size kernel_sha256 root_size root_sha256 \
		offset config config_size config_sha256 trial; do
		eval "X_$k=\$(au_ctx $k)"
	done
	AU_TOKEN="$X_token"
	au_is_hex "$X_token" 32 && [ "$(cat "$AU_RUN/token" 2>/dev/null)" = "$X_token" ] &&
		[ "$X_boot_id" = "$(au_boot_id)" ] && [ "$X_booted" = "$BC_CUR" ] && [ "$X_target" = "$BC_OTHER" ] || return 1
	for k in kernel_size root_size offset config_size; do
		eval "case \"\$X_$k\" in ''|*[!0-9]*) return 1 ;; esac"
	done
	au_is_hex "$X_image_sha256" 64 && au_is_hex "$X_kernel_sha256" 64 && au_is_hex "$X_root_sha256" 64 || return 1
	[ $((X_offset % 65536)) = 0 ] && [ "$X_offset" -ge "$X_root_size" ] && [ "$X_kernel_size" = "$AU_KERNEL_SIZE" ] || return 1
	case "$X_config" in 0) ;; 1) au_is_hex "$X_config_sha256" 64 || return 1 ;; *) return 1 ;; esac
	bc_valid "$X_record" || return 1
}

# do_invalidate / do_activate run in a subshell holding the boot control lock; "@inv OLD NEW READ" and
# "@act OLD NEW READ" report the write, "@write" comes right before it.
au_do_invalidate() {
	local r n rc
	r="$(bc_read)" || return 5
	echo "@cur $r"
	bc_reservation_owned "$1" || { echo "the update reservation is not this run's" >&2; return 3; }
	[ "$r" = "$2" ] || { echo "the boot control record changed since the admission ($2 -> $r)" >&2; return 3; }
	[ "$(bc_next "$r")" = "$BC_CUR" ] && [ "$(bc_get "$r" "$BC_CUR" success)" = 01 ] ||
		{ echo "the booted slot is no longer next and successful ($r)" >&2; return 3; }
	n="$(bc_invalidate "$r" "$BC_OTHER")" || return 3
	echo "@write"
	bc_write "$r" "$n"; rc=$?
	echo "@inv $r $n $(bc_read 2>/dev/null || echo unknown)"
	return "$rc"
}

au_do_activate() {
	local r n rc
	r="$(bc_read)" || return 5
	echo "@cur $r"
	bc_reservation_owned "$1" || { echo "the update reservation is not this run's" >&2; return 3; }
	[ "$r" = "$2" ] || { echo "the boot control record changed since the invalidate ($2 -> $r)" >&2; return 3; }
	n="$(bc_activate_written "$r" "$BC_OTHER")" || return 3
	echo "@write"
	bc_write "$r" "$n"; rc=$?
	echo "@act $r $n $(bc_read 2>/dev/null || echo unknown)"
	return "$rc"
}

au_in_lock() { trap '' INT TERM; "$@"; }
au_data() { printf '%s\n' "$1" | sed -n "s/^@$2 //p" | head -n 1; }

# au_bc_step NAME FUNC ARGS: run a boot control change; sets AU_LAST and AU_SURE from what was read back.
au_bc_step() {
	local name="$1" a rc d
	shift
	a="$(bc_with_lock au_in_lock "$@" 2>&1)"; rc=$?
	d="$(au_data "$a" cur)"; [ -z "$d" ] || AU_LAST="$d"
	d="$(au_data "$a" "$name")"
	# The write was started (or may have been): the run changed something, even if the step reports a failure.
	printf '%s\n' "$a" | grep -qx '@write' && AU_WROTE=1
	if [ -n "$d" ]; then
		set -- $d
		AU_LAST="$3"
		au_rec "phase=$name" "old=$1" "requested=$2" "read-back=$3" "rc=$rc"
		[ "$3" = "$1" ] || [ "$3" = "$2" ] || AU_SURE=
		[ "$rc" = 0 ] && [ "$3" = "$2" ] && return 0
		return 6
	fi
	if printf '%s\n' "$a" | grep -qx '@write'; then
		AU_SURE=
		AU_LAST="$(bc_read 2>/dev/null)" || AU_LAST=unknown
		au_rec "phase=$name" "result=cut-off" "read=$AU_LAST" "rc=$rc"
		return 6
	fi
	au_err "$name refused (rc $rc): $(printf '%s\n' "$a" | grep -v '^@' | tr '\n' ' ')"
	return 3
}

# au_dd_read DEV SKIP_BLOCKS BYTES: sha256 of BYTES bytes of DEV from 4 KiB block SKIP_BLOCKS.
au_dd_read() {
	dd if="$1" bs=4096 skip="$2" count=$(( ($3 + 4095) / 4096 )) 2>/dev/null | head -c "$3" | sha256sum | cut -d' ' -f1
}

au_write() {
	local zero b
	AU_PHASE=check-copies
	[ "$(au_sha "$AU_RUN/image")" = "$X_image_sha256" ] && [ "$(au_sha "$AU_RUN/kernel")" = "$X_kernel_sha256" ] &&
		[ "$(au_sha "$AU_RUN/root")" = "$X_root_sha256" ] || { au_err "the run copies changed since the admission"; return 3; }
	if [ "$X_config" = 1 ]; then
		[ "$(au_sha "$AU_RUN/config.tgz")" = "$X_config_sha256" ] || { au_err "the config copy changed since the admission"; return 3; }
	fi
	au_part "boot_$BC_OTHER" PB && au_part "rootfs_$BC_OTHER" PR || { au_err "target partitions not found"; return 3; }
	AU_PHASE=invalidate
	au_bc_step inv au_do_invalidate "$AU_TOKEN" "$X_record" || return $?
	AU_PHASE=write-kernel
	dd if="$AU_RUN/kernel" of="$PB_dev" bs=1M conv=notrunc,fsync 2>/dev/null || { au_err "writing boot_$BC_OTHER failed"; return 6; }
	AU_PHASE=write-root
	dd if="$AU_RUN/root" of="$PR_dev" bs=1M conv=notrunc,fsync 2>/dev/null || { au_err "writing rootfs_$BC_OTHER failed"; return 6; }
	AU_PHASE=write-overlay
	b=$((X_offset / 4096))
	dd if=/dev/zero of="$PR_dev" bs=4096 seek="$b" count=1 conv=notrunc,fsync 2>/dev/null ||
		{ au_err "clearing the overlay header failed"; return 6; }
	if [ "$X_config" = 1 ]; then
		dd if="$AU_RUN/config.tgz" of="$PR_dev" bs=4096 seek="$b" conv=notrunc,fsync 2>/dev/null ||
			{ au_err "writing the config backup failed"; return 6; }
	fi
	AU_PHASE=read-back
	sync
	echo 3 > "$AU_PROC/sys/vm/drop_caches" 2>/dev/null || { au_err "dropping the page cache failed; not activating"; return 6; }
	[ "$(au_dd_read "$PB_dev" 0 "$X_kernel_size")" = "$X_kernel_sha256" ] || { au_err "boot_$BC_OTHER read-back differs"; return 6; }
	[ "$(au_dd_read "$PR_dev" 0 "$X_root_size")" = "$X_root_sha256" ] || { au_err "rootfs_$BC_OTHER read-back differs"; return 6; }
	if [ "$X_config" = 1 ]; then
		[ "$(au_dd_read "$PR_dev" "$b" "$X_config_size")" = "$X_config_sha256" ] || { au_err "config read-back differs"; return 6; }
	else
		zero="$(head -c 4096 /dev/zero | sha256sum | cut -d' ' -f1)"
		[ "$(au_dd_read "$PR_dev" "$b" 4096)" = "$zero" ] || { au_err "overlay header read-back is not zero"; return 6; }
	fi
	au_rec "phase=read-back" "result=ok" "config=$X_config"
	AU_PHASE=activate
	au_bc_step act au_do_activate "$AU_TOKEN" "$AU_LAST" || return $?
	AU_ACTIVATED=1
}

au_led_halt() {
	local l
	for l in "$AU_LEDS"/green:power "$AU_LEDS"/red:power; do
		[ -d "$l" ] || continue
		echo none > "$l/trigger" 2>/dev/null; echo 0 > "$l/brightness" 2>/dev/null
	done
	[ -d "$AU_LEDS/red:power" ] && { echo timer > "$AU_LEDS/red:power/trigger"; } 2>/dev/null
}

# au_halt: the record is not certain. Never returns: the upgraded process keeps the watchdog fed while stage2 runs.
au_halt() {
	au_rec "end=1" "state=halted" "phase=$AU_PHASE" "last=${AU_LAST:-unknown}"
	au_led_halt
	{
		echo
		echo "air6-upgrade: STOPPED in phase $AU_PHASE. The boot control record is not certain (last read: ${AU_LAST:-unknown})."
		echo "air6-upgrade: nothing is rebooted automatically. Without a serial console: power-cycle the unit."
		echo "air6-upgrade: record: dd if=$BC_DEV bs=1 skip=$BC_REC_OFF count=$BC_REC_LEN | hexdump -C"
		echo "air6-upgrade: reboot after a check: reboot -f"
	} > "$AU_CONSOLE" 2>/dev/null
	if [ -n "${AU_HALT_CMD:-}" ]; then $AU_HALT_CMD; return 0; fi
	while :; do
		/bin/sh -i < "$AU_CONSOLE" > "$AU_CONSOLE" 2>&1 || sleep 5
	done
}

# au_finish STATE: the end of a run that did not halt.
au_finish() {
	[ -n "$AU_LOADED" ] && { bc_with_lock bc_release "$AU_TOKEN" >/dev/null 2>&1 || au_err "own update reservation not removed"; }
	au_rec "end=1" "state=$1" "phase=$AU_PHASE" "from=$BC_CUR" "to=$BC_OTHER" "image=${X_image_sha256:-unknown}" "last=${AU_LAST:-none}"
	return 0
}

# au_safe: the record read now is certain and keeps the booted slot next and successful.
au_safe() {
	local r
	[ -n "$AU_SURE" ] || return 1
	r="$(bc_read 2>/dev/null)" || return 1
	AU_LAST="$r"
	bc_valid "$r" && [ "$(bc_next "$r")" = "$BC_CUR" ] && [ "$(bc_get "$r" "$BC_CUR" success)" = 01 ]
}

au_do_upgrade() {
	local rc
	AU_STAGE2=1 AU_WROTE= AU_ACTIVATED= AU_LOADED= AU_RUN= AU_PHASE=load
	# Stage2 must not end on a signal (upgraded reboots as soon as it exits): every path below ends in a terminal
	# state. Children inherit the ignored signals, so a boot control step is never cut between write and read-back.
	trap '' INT TERM HUP PIPE
	if ! bc_init; then
		au_err "boot control not readable in stage2"
		au_halt
		return 0
	fi
	if ! au_load; then
		AU_PHASE=not-admitted
		# Name the end line after the run that was not admitted (its token file), never reuse its reservation.
		AU_TOKEN=-
		[ -n "$AU_RUN" ] && [ -f "$AU_RUN/token" ] && AU_TOKEN="$(cat "$AU_RUN/token")"
		au_is_hex "$AU_TOKEN" 32 || AU_TOKEN=-
		au_say "this run was not admitted; nothing written"
		if au_safe; then au_finish refused; else au_halt; fi
		return 0
	fi
	AU_LOADED=1
	au_rec "phase=write-start" "target=$BC_OTHER" "trial=$X_trial"
	au_write; rc=$?
	if [ "$rc" = 0 ] && [ -n "$AU_ACTIVATED" ]; then
		au_finish written
		au_say "slot $BC_OTHER written and selected for the next boot (trial of the preloader: retry 02)"
		return 0
	fi
	if [ -z "$AU_WROTE" ] && au_safe; then au_finish refused; return 0; fi
	if au_safe; then au_finish failed; return 0; fi
	au_halt
	return 0
}
