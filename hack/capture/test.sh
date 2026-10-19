#!/usr/bin/env bash
# Dry-run the capture driver over every scenario in both NPD variants.
#
#   hack/capture/test.sh <tropis binary>
#
# Needs no root, cluster or disk: --dry-run only prints the plan. Run by
# `make capture-test`, part of `make check`, so a scenario added to
# scenarios.yaml that run-scenario.sh cannot drive fails the build. For each
# run it checks the plan has the steps the scenario needs, in the order 4.7
# of docs/capture-rig.md gives, and never forces a capture.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TROPIS="$1"
export TROPIS_BIN="$TROPIS"
export TROPIS_INVENTORY="$REPO/hack/inventory.example.yaml" TROPIS_NODE=worker-02 TROPIS_DISK=sacrificial
unset RETAKE

failures=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

# has OUT TEXT / lacks OUT TEXT: fixed-string checks on a plan.
has() { grep -qF -- "$2" <<<"$1"; }
line_of() { grep -nF -- "$2" <<<"$1" | head -n1 | cut -d: -f1; }

ids="$("$TROPIS" scenario list)" || { echo "tropis scenario list failed" >&2; exit 2; }
[ -n "$ids" ] || { echo "no scenarios" >&2; exit 2; }

for id in $ids; do
	eval "$("$TROPIS" scenario show "$id")"
	for variant in npd-absent npd-present; do
		name="$id/$variant"
		if ! plan="$(bash "$HERE/run-scenario.sh" --dry-run "$id" "$variant" 2>&1)"; then
			fail "$name: the driver refused it:"
			printf '%s\n' "$plan" | tail -n 5 | sed 's/^/    /'
			continue
		fi
		bad=""
		problem() { bad="$bad; $*"; }

		has "$plan" "capture --scenario $id --variant $variant" || problem "no capture"
		has "$plan" "--force" && problem "forces the capture"
		has "$plan" "mkfs.ext4 -q -F /dev/mapper/tropis-target" || problem "no mkfs at reset"
		has "$plan" "delete namespace tropis-eval" || problem "no namespace reset"
		has "$plan" "envsubst" || problem "no workload"
		has "$plan" "k8sgpt.txt" || problem "no k8sgpt baseline"
		has "$plan" "sleep: 900s" || problem "no baseline wait"
		[ "$(grep -c '^operator: ' <<<"$plan")" -ge 2 ] || problem "symptom never confirmed by the operator"
		if [ "$variant" = npd-present ]; then
			has "$plan" "rollout status daemonset node-problem-detector" || problem "NPD not checked"
		else
			has "$plan" "no NPD conditions" || problem "absence of NPD not checked"
		fi

		if [ -n "$INJECT_SCRIPT" ]; then
			has "$plan" "hack/inject/$INJECT_SCRIPT start" || problem "no $INJECT_SCRIPT start"
			has "$plan" "on exit: TROPIS_INJECT_CONFIRM=" || problem "fault not stopped on exit"
			has "$plan" "--injection" || problem "no --injection"
			for p in $INJECT_PARAMS; do
				has "$plan" "$p" || problem "param $p not passed"
			done
			inject_at="$(line_of "$plan" "hack/inject/$INJECT_SCRIPT start")"
			apply_at="$(line_of "$plan" "envsubst")"
			if [ "$INJECT_SCRIPT" = ephemeral-exhaustion.sh ]; then
				[ "${inject_at:-0}" -lt "${apply_at:-0}" ] || problem "exhaustion must inject before the workload"
				has "$plan" "DiskPressure False" || problem "DiskPressure not checked"
			else
				[ "${apply_at:-0}" -lt "${inject_at:-0}" ] || problem "workload must come before the fault"
			fi
			[ "$INJECT_SCRIPT" = containerd-kill.sh ] && { has "$plan" "type worker-02/containerd" || problem "containerd confirmation not asked"; }
		else
			has "$plan" "--injection" && problem "--injection without a fault"
			grep -qE 'hack/inject/[a-z-]+\.sh start' <<<"$plan" && problem "injects with no inject"
		fi
		if [ -n "$INJECT_TARGET" ]; then
			if [ "$INJECT_SCRIPT" = fs-corruption.sh ]; then
				has "$plan" "VICTIM=" || problem "target not passed as VICTIM"
			else
				has "$plan" "target-blocks.sh" || problem "target-blocks.sh not used"
			fi
		fi
		if [ -n "$SYMPTOM_SCRIPT" ]; then
			has "$plan" "hack/symptoms/$SYMPTOM_SCRIPT start" || problem "no $SYMPTOM_SCRIPT"
			has "$plan" "type worker-02/silent-kill" || problem "silent-kill confirmation not asked"
			has "$plan" "symptoms/$SYMPTOM_SCRIPT' stop" || problem "symptom not stopped on exit"
			[ "$(line_of "$plan" "hack/symptoms/$SYMPTOM_SCRIPT start")" -gt "$(line_of "$plan" "envsubst")" ] || problem "symptom before the workload"
		fi
		for c in $EXPECT_SMART; do
			has "$plan" "expectSmart counter ($EXPECT_SMART)" || problem "expectSmart $c not waited for"
		done
		case " $HARDWARE " in
		*" real-sata "*) has "$plan" "rollout restart daemonset tropis-collector" || problem "collector not restarted" ;;
		*) has "$plan" "rollout restart daemonset tropis-collector" && problem "collector restarted, losing its history" ;;
		esac
		case " $HARDWARE " in *" scarred-sata "*) has "$plan" "at least 24 h" || problem "collector age not checked" ;; esac
		case " $HARDWARE " in *" smart-withheld "*)
			has "$plan" "runAsUser" || problem "collector not patched"
			has "$plan" "rollout undo daemonset tropis-collector" || problem "collector patch not undone" ;;
		esac

		if [ -z "$bad" ]; then
			pass "$name"
		else
			fail "$name:${bad#;}"
		fi
	done
done

# A scenario the driver cannot run must be refused, not half-run. A stub
# tropis serves a scenario with an unknown script, symptom, target or
# hardware and passes everything else to the real binary; served unchanged
# first, to show the stub itself works.
stub="$(mktemp -d)"
trap 'rm -rf "$stub"' EXIT
for case in "" "INJECT_SCRIPT='no-such.sh'" "SYMPTOM_SCRIPT='no-such.sh'" \
	"INJECT_SCRIPT='write-errors.sh' INJECT_TARGET='batch/dataset'" "HARDWARE='nvme'" "EXPECT_SMART='temperature'"; do
	cat >"$stub/tropis" <<EOF
#!/usr/bin/env bash
if [ "\$1" = scenario ]; then
	"$TROPIS" scenario show read-errors-batch
	echo "$case"
	exit 0
fi
exec "$TROPIS" "\$@"
EOF
	chmod +x "$stub/tropis"
	if TROPIS_BIN="$stub/tropis" bash "$HERE/run-scenario.sh" --dry-run read-errors-batch npd-absent >/dev/null 2>&1; then
		if [ -z "$case" ]; then pass "the stub serves a drivable scenario"; else fail "accepted a scenario it cannot drive: $case"; fi
	else
		if [ -z "$case" ]; then fail "the stub itself is broken"; else pass "refuses a scenario it cannot drive: $case"; fi
	fi
done
if bash "$HERE/run-scenario.sh" --dry-run read-errors-batch npd-maybe >/dev/null 2>&1; then
	fail "accepted variant npd-maybe"
else
	pass "refuses an unknown variant"
fi

echo
if [ "$failures" -eq 0 ]; then
	echo "capture driver: every scenario planned"
else
	echo "capture driver: $failures failure(s)"
fi
exit "$failures"
