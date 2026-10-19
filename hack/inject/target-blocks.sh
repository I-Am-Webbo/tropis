#!/usr/bin/env bash
# Print bad-sector targets that lie under a given file.
#
#   target-blocks.sh <file>
#
# The bad-sector faults default to the middle of the disk, which no workload
# need be anywhere near. For a scenario whose symptom is a workload reading
# its own data (postgres's relation files, log-writer's segments,
# batch/dataset), the fault has to sit under that data. Given a file on the
# filesystem on /dev/mapper/tropis-target, this prints, ready to eval:
#
#   SECTORS='...'     physical 512-byte LBAs on the target disk, for
#                     pending-sectors.sh and hdparm
#   BAD_BLOCKS='...'  512-byte blocks of /dev/mapper/tropis-target, for
#                     read-errors.sh (dm-dust's block size there is 512)
#
# one sector per chosen filesystem block, so a read of any of those blocks
# fails. The blocks are COUNT (default 4, at most 64) spread evenly through
# the file's allocated blocks. The variables are printed unexported, so pass
# them explicitly and a later scenario that wants the defaults is not hit:
#
#   eval "$(hack/inject/target-blocks.sh /mnt/disks/sacrificial/batch/dataset)"
#   BAD_BLOCKS="$BAD_BLOCKS" hack/inject/read-errors.sh start > fault.json
#
# Read-only: it changes nothing. Units are read, not assumed: the
# filesystem's block size from filefrag's own header, and the pass-through
# table's offset onto the disk from dmsetup. It refuses a file not on the
# tropis-target filesystem, a table that is not the plain pass-through (a
# fault is active: compute targets before injecting), a target that is a
# partition rather than a whole disk (hdparm addresses whole-disk LBAs), and
# a disk whose logical sectors are not 512 bytes.
. "$(dirname "$0")/lib.sh"

[ "$#" -eq 1 ] || { echo "usage: $(basename "$0") <file>" >&2; exit 64; }
file="$1"
count="${COUNT:-4}"

require_root
require_cmd dmsetup filefrag findmnt
case "$count" in
'' | *[!0-9]*) die "COUNT must be a number" ;;
esac
[ "$count" -ge 1 ] && [ "$count" -le 64 ] || die "COUNT must be between 1 and 64"
[ -f "$file" ] || die "$file is not a regular file"
require_prepared

# The file must be on the filesystem on the pass-through device.
src="$(findmnt -nro SOURCE -T "$file")" || die "cannot find the filesystem holding $file"
src="${src%%\[*}"
[ "$(readlink -f "$src")" = "$(readlink -f "$(dm_path)")" ] ||
	die "refusing: $file is on $src, not on $(dm_path)"

# The pass-through: one linear line mapping the device onto the disk.
table="$(dmsetup table "$DM_NAME")"
[ "$(printf '%s\n' "$table" | wc -l)" -eq 1 ] ||
	die "$DM_NAME is not the plain pass-through (a fault is active?); compute targets before injecting"
read -r start _ kind dev offset _ <<<"$table"
[ "$kind" = linear ] && [ "$start" = 0 ] ||
	die "$DM_NAME is a $kind table, not the plain pass-through (a fault is active?); compute targets before injecting"
# Every fault table in lib.sh maps device sector s to disk sector s, so a
# pass-through at any other offset would not be what the faults replace.
[ "$offset" = 0 ] || die "$DM_NAME maps onto $dev at offset $offset, but the fault tables assume 0; recreate it with prepare.sh"
sys="/sys/dev/block/$dev"
[ -e "$sys" ] || die "cannot find device $dev in sysfs"
[ -e "$sys/partition" ] && die "$DM_NAME sits on a partition; hdparm addresses whole-disk LBAs, so target a whole disk"
lbs="$(cat "$sys/queue/logical_block_size")"
[ "$lbs" = 512 ] || die "the disk's logical sectors are $lbs bytes; pending-sectors.sh assumes 512"

# Allocate any delayed blocks, so the extents are on disk.
sync "$file"

frag="$(filefrag -v "$file")" || die "filefrag failed on $file"
bs="$(printf '%s\n' "$frag" | sed -n 's/.*blocks of \([0-9][0-9]*\) bytes.*/\1/p' | head -n1)"
[ -n "$bs" ] && [ "$bs" -ge 512 ] && [ $((bs % 512)) -eq 0 ] ||
	die "cannot read the filesystem block size from filefrag"

# Extent lines: "ext: logical_start.. logical_end: physical_start..
# physical_end: length: [expected:] flags". Extents not yet written or not
# at a known place are skipped.
picks="$(printf '%s\n' "$frag" | awk -v n="$count" '
	BEGIN { e = 0; total = 0 }
	/^ *[0-9]+:/ {
		if ($0 ~ /unwritten|unknown_loc|delalloc|inline|encoded/) next
		line = $0
		gsub(/\.\./, " ", line); gsub(/:/, " ", line)
		split(line, f, " ")
		len = f[6] + 0
		if (len <= 0) next
		phys[e] = f[4] + 0; size[e] = len; total += len; e++
	}
	END {
		if (total == 0) exit 1
		if (n > total) n = total
		for (i = 0; i < n; i++) {
			k = int((2 * i + 1) * total / (2 * n))
			for (j = 0; j < e; j++) {
				if (k < size[j]) { print phys[j] + k; break }
				k -= size[j]
			}
		}
	}')" || die "$file has no allocated blocks on disk"

per=$((bs / 512))
sectors="" blocks="" fsblocks=""
for p in $picks; do
	blocks="$blocks $((p * per))"
	sectors="$sectors $((p * per + offset))"
	fsblocks="$fsblocks $p"
done
log "$file: ${bs}-byte filesystem blocks${fsblocks}; table offset $offset"
echo "SECTORS='${sectors# }'"
echo "BAD_BLOCKS='${blocks# }'"
