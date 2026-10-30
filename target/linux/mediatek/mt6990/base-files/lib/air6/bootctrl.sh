# Boot control record of the SoftBank Air 6 (misc partition), shared by air6-slot and later writers.
#
# Layout (stock /lib/upgrade/bootctrl.sh): misc+2052 holds the magic "BCAB"; misc+2060 holds a 10-byte record,
# 5 bytes per slot: priority, retry, success, uptype, reserved (slot a at 0..4, slot b at 5..9). A record is handled
# as 20 hex digits. Callers use slot names and field names only; offsets stay in this file.
#
# Sourcing this file has no side effects. Functions return, they never exit the caller:
#   0 done (also when the record already was in the requested state)
#   3 refused, nothing changed (precondition not met)
#   4 busy, nothing changed (lock not acquired)
#   5 environment or read error, nothing changed
#   6 failed after a write was started (the record may have changed; read it again)
#
# The record is written with one 10-byte write, then flushed and read back. "Verified" means that read-back
# matched; it does not mean the write is atomic against a power cut.
#
# Overrides for host tests only: BC_MISC_DEV, BC_CMDLINE, BC_LOCK, BC_LOCK_TRIES, BC_RESERVATION, BC_FUNCTIONS (and
# in air6-slot: AIR6_SLOT_LIB, AIR6_SLOT_RUN, AIR6_SLOT_ETC, AIR6_UPTIME).

BC_MAGIC_OFF=2052
BC_REC_OFF=2060
BC_REC_LEN=10
BC_PRIO_HIGH=0f
BC_PRIO_LOW=0e
: "${BC_CMDLINE:=/proc/cmdline}"
: "${BC_LOCK:=/tmp/lock/air6-bootctrl.lock}"
: "${BC_LOCK_TRIES:=10}"
: "${BC_RESERVATION:=/tmp/air6-update}"
: "${BC_FUNCTIONS:=/lib/functions.sh}"

# bc_cmdline_value KEY: the value of the single KEY= token on the kernel command line; fails if absent or repeated.
bc_cmdline_value() {
	local v
	v="$(tr -s ' \t\n' '\n' < "$BC_CMDLINE" 2>/dev/null | sed -n "s/^$1=//p")" || return 1
	[ -n "$v" ] && [ "$(echo "$v" | wc -l)" = 1 ] || return 1
	echo "$v"
}

# bc_current: booted slot (a or b) from bootslot= on the kernel command line.
bc_current() {
	local s
	s="$(bc_cmdline_value bootslot)" || return 5
	case "$s" in
	a|b) echo "$s" ;;
	*) return 5 ;;
	esac
}

bc_opposite() { [ "$1" = a ] && echo b || echo a; }

# bc_init: check the board and the magic, set BC_DEV, BC_CUR and BC_OTHER.
bc_init() {
	[ -n "$BC_MISC_DEV" ] && BC_DEV="$BC_MISC_DEV" || {
		type find_mmc_part >/dev/null 2>&1 || . "$BC_FUNCTIONS" || return 5
		[ "$(board_name)" = "softbank,air6" ] || { echo "not a SoftBank Air 6" >&2; return 5; }
		BC_DEV="$(find_mmc_part misc)"
	}
	[ -n "$BC_DEV" ] && [ -e "$BC_DEV" ] || { echo "misc partition not found" >&2; return 5; }
	[ "$(dd if="$BC_DEV" bs=1 skip="$BC_MAGIC_OFF" count=4 2>/dev/null)" = BCAB ] ||
		{ echo "boot control magic missing" >&2; return 5; }
	BC_CUR="$(bc_current)" || { echo "bootslot not on the kernel command line" >&2; return 5; }
	BC_OTHER="$(bc_opposite "$BC_CUR")"
}

# bc_read: the current record as 20 hex digits.
bc_read() {
	local r
	r="$(dd if="$BC_DEV" bs="$BC_REC_LEN" skip=$((BC_REC_OFF / BC_REC_LEN)) count=1 2>/dev/null |
		hexdump -v -e '1/1 "%02x"')"
	[ "${#r}" = $((BC_REC_LEN * 2)) ] || { echo "short read of the boot control record" >&2; return 5; }
	echo "$r"
}

# bc_pos SLOT FIELD: position of the field's first hex digit in a record string (1-based).
bc_pos() {
	local base i
	case "$1" in a) base=0 ;; b) base=5 ;; *) return 5 ;; esac
	case "$2" in prio) i=0 ;; retry) i=1 ;; success) i=2 ;; uptype) i=3 ;; *) return 5 ;; esac
	echo $(((base + i) * 2 + 1))
}

# bc_get REC SLOT FIELD: one field as two hex digits.
bc_get() {
	local p
	p="$(bc_pos "$2" "$3")" || return 5
	echo "$1" | cut -c"$p-$((p + 1))"
}

# bc_set REC SLOT FIELD HEX: the record with one field replaced.
bc_set() {
	local p
	p="$(bc_pos "$2" "$3")" || return 5
	case "$4" in [0-9a-f][0-9a-f]) ;; *) return 5 ;; esac
	echo "$1" | sed "s/^\(.\{$((p - 1))\}\)../\1$4/"
}

# bc_valid REC: success bytes are 00/01 and priorities are 0e/0f.
bc_valid() {
	local s f v
	for s in a b; do
		for f in prio success; do
			v="$(bc_get "$1" "$s" "$f")"
			case "$f:$v" in
			prio:0e|prio:0f|success:00|success:01) ;;
			*) return 1 ;;
			esac
		done
	done
}

# bc_next REC: slot the preloader prefers (a, b or unknown when the priorities do not decide it).
bc_next() {
	local pa pb
	pa="$(bc_get "$1" a prio)"; pb="$(bc_get "$1" b prio)"
	if [ "$pa" = "$BC_PRIO_HIGH" ] && [ "$pb" = "$BC_PRIO_LOW" ]; then echo a
	elif [ "$pb" = "$BC_PRIO_HIGH" ] && [ "$pa" = "$BC_PRIO_LOW" ]; then echo b
	else echo unknown
	fi
}

# bc_hex2bytes HEX: the bytes, written by a single printf.
bc_hex2bytes() {
	local h="$1" f=""
	while [ -n "$h" ]; do
		f="$f\\$(printf '%03o' "0x$(echo "$h" | cut -c1-2)")"
		h="$(echo "$h" | cut -c3-)"
	done
	printf "$f"
}

# bc_write OLD NEW: write NEW if it differs from OLD, flush, read back.
bc_write() {
	[ "$1" = "$2" ] && return 0
	case "$2" in *[!0-9a-f]*) echo "refusing to write a malformed record '$2'" >&2; return 5 ;; esac
	[ "${#2}" = $((BC_REC_LEN * 2)) ] && bc_valid "$2" ||
		{ echo "refusing to write a malformed record '$2'" >&2; return 5; }
	bc_hex2bytes "$2" | dd of="$BC_DEV" bs="$BC_REC_LEN" seek=$((BC_REC_OFF / BC_REC_LEN)) count=1 \
		iflag=fullblock conv=notrunc,fsync 2>/dev/null || { echo "boot control write failed" >&2; return 6; }
	sync
	[ "$(bc_read)" = "$2" ] || { echo "boot control read-back mismatch" >&2; return 6; }
}

# bc_with_lock CMD [ARGS]: run CMD in a subshell holding the boot control lock. CMD must not take the lock again.
bc_with_lock() {
	(
		i=0
		mkdir -p "$(dirname "$BC_LOCK")" 2>/dev/null
		# 'command' strips exec's special-builtin status: a failed redirection then returns non-zero instead of exiting.
		{ command exec 9>"$BC_LOCK"; } 2>/dev/null || { echo "cannot open or create $BC_LOCK" >&2; exit 5; }
		command -v flock >/dev/null || { echo "flock not available" >&2; exit 5; }
		while :; do
			flock -n 9; rc=$?
			[ "$rc" = 0 ] && break
			[ "$rc" = 1 ] || { echo "flock failed ($rc)" >&2; exit 5; }
			i=$((i + 1))
			[ "$i" -lt "$BC_LOCK_TRIES" ] || { echo "boot control is busy" >&2; exit 4; }
			sleep 1
		done
		"$@"
	)
}

# Transitions: bc_<name> REC ... prints the new record; 3 when refused. They do not write.

# bc_select_successful REC TARGET: TARGET boots next. TARGET must be successful; unless it is the booted slot its
# retry is reset to 00 (the preloader refuses to switch to a slot with a high retry).
bc_select_successful() {
	local r="$1" t="$2" o
	o="$(bc_opposite "$t")"
	[ "$(bc_get "$r" "$t" success)" = 01 ] || return 3
	[ "$t" = "$BC_CUR" ] || r="$(bc_set "$r" "$t" retry 00)"
	r="$(bc_set "$r" "$t" prio "$BC_PRIO_HIGH")"
	bc_set "$r" "$o" prio "$BC_PRIO_LOW"
}

# bc_mark_success REC SLOT: SLOT successful with retry 00.
bc_mark_success() {
	bc_set "$(bc_set "$1" "$2" retry 00)" "$2" success 01
}

# bc_reset_retry REC SLOT
bc_reset_retry() {
	bc_set "$1" "$2" retry 00
}

# Writers of a slot that is not booted (restore-stock, later sysupgrade) use two transitions around the partition
# writes: bc_invalidate before the first write, bc_activate_written after all writes were read back.

# bc_invalidate REC TARGET: TARGET unsuccessful, so that neither a manual selection nor the LEVEL switch picks a
# half-written slot. Refused for the booted slot.
bc_invalidate() {
	[ "$2" != "$BC_CUR" ] || return 3
	bc_set "$1" "$2" success 00
}

# bc_activate_written REC TARGET: TARGET boots next as a trial of the preloader (success 00, retry preset 02, so two
# boots before the preloader returns to the booted slot). TARGET must be invalidated and must not be the booted slot;
# the booted slot keeps its success and retry.
bc_activate_written() {
	local r="$1" t="$2"
	[ "$t" != "$BC_CUR" ] && [ "$(bc_get "$r" "$t" success)" = 00 ] || return 3
	r="$(bc_set "$r" "$t" retry 02)"
	r="$(bc_set "$r" "$t" prio "$BC_PRIO_HIGH")"
	bc_set "$r" "$(bc_opposite "$t")" prio "$BC_PRIO_LOW"
}

# Update reservation: a file that marks a running write of the other slot. It is separate from the short lock (a
# writer holds it for minutes) and lives in /tmp, so it ends with the boot; bc_invalidate keeps a half-written slot
# unselectable after that. Create and remove it with the lock held. Content: one line of KEY=VALUE fields, the first
# being token=.

# bc_reservation: print the reservation and succeed if one exists.
bc_reservation() {
	[ -e "$BC_RESERVATION" ] || return 1
	cat "$BC_RESERVATION" 2>/dev/null || echo "token=unreadable"
}

# bc_reserve TOKEN FIELDS: create the reservation; 4 if one exists, 5 if it cannot be stored.
bc_reserve() {
	local line="token=$1 $2"
	[ -e "$BC_RESERVATION" ] && { echo "an update is in progress: $(bc_reservation)" >&2; return 4; }
	mkdir -p "$(dirname "$BC_RESERVATION")" 2>/dev/null
	( umask 077; echo "$line" > "$BC_RESERVATION.tmp" ) 2>/dev/null && mv "$BC_RESERVATION.tmp" "$BC_RESERVATION" 2>/dev/null &&
		[ "$(cat "$BC_RESERVATION" 2>/dev/null)" = "$line" ] && return 0
	rm -f "$BC_RESERVATION.tmp" 2>/dev/null
	echo "update reservation not stored in $BC_RESERVATION" >&2
	return 5
}

# bc_reservation_owned TOKEN: the reservation exists and carries TOKEN.
bc_reservation_owned() {
	case "$(bc_reservation)" in "token=$1 "*|"token=$1") return 0 ;; esac
	return 1
}

# bc_release TOKEN: remove the reservation if it carries TOKEN; 3 if it is another one, 0 if there is none.
bc_release() {
	[ -e "$BC_RESERVATION" ] || return 0
	bc_reservation_owned "$1" || { echo "the update reservation belongs to another run: $(bc_reservation)" >&2; return 3; }
	rm -f "$BC_RESERVATION" || return 5
}
