#!/usr/bin/env bash
# Drive one capture: one scenario, one NPD variant, start to finish.
#
#   hack/capture/run-scenario.sh [--dry-run] <scenario-id> <npd-absent|npd-present>
#
# Runs on the capture worker as root, from a checkout of the repository, and
# does the mechanical steps of docs/capture-rig.md 4.7 in order: check the
# NPD variant, reset (delete tropis-eval, mkfs and remount the target, and
# for a SMART-visible scenario restart the collector and wait for its fresh
# reading), apply the workload, aim and inject the fault, start the
# scenario's symptom helper, wait for what can be checked, ask the operator
# to confirm what cannot, hold the fault 15 minutes for the baseline, save
# k8sgpt's output, run `tropis capture`, and stop the fault. Every record
# goes to a run directory outside eval/fixtures.
#
# Scenario data comes only from `tropis scenario show`, which reads the
# scenarios built into the tropis binary; nothing here repeats it. A
# scenario using a script, target, symptom, hardware kind or counter this
# driver does not know is refused, in --dry-run too, so the dry-run test over
# every scenario fails when one is added that it cannot run.
#
# Nothing is forced or skipped. The injection scripts' own checks
# (inventory, destructible, TROPIS_INJECT_CONFIRM) apply as always; the
# containerd and silent-kill confirmations are typed by the operator at the
# prompt; a capture refusal stops the run, and the fault is stopped on any
# exit. --force reaches capture only with RETAKE=1, for a retake decided
# before anyone looked at a verdict.
#
# --dry-run prints the plan and the commands without running anything; it
# needs no root, no cluster and no disk, only the inventory and tropis.
#
# Environment:
#   TROPIS_INVENTORY, TROPIS_NODE, TROPIS_DISK   as for hack/inject (required)
#   TROPIS_INJECT_CONFIRM  "$TROPIS_NODE/$TROPIS_DISK" (required, live only)
#   TROPIS_BIN, TROPIS_COLLECTOR  binaries (default: on PATH)
#   TROPIS_RUN_ROOT   where run directories go (default /var/lib/tropis-capture/runs)
#   TROPIS_CORPUS     capture --corpus (default eval/fixtures in the checkout)
#   RETAKE=1          replace an existing fixture (capture --force)
#   PROM_PORT         local port for Prometheus (default 19090)
#   K8SGPT            k8sgpt binary (default k8sgpt)
. "$(dirname "$0")/../inject/lib.sh"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
INJECT="$REPO/hack/inject"
SYMPTOMS="$REPO/hack/symptoms"
K8SGPT="${K8SGPT:-k8sgpt}"
PROM_PORT="${PROM_PORT:-19090}"
RUN_ROOT="${TROPIS_RUN_ROOT:-/var/lib/tropis-capture/runs}"
CORPUS="${TROPIS_CORPUS:-$REPO/eval/fixtures}"
NS=tropis-eval
COLLECTOR_NS=tropis-system
COLLECTOR_DS=tropis-collector
COLLECTOR_SELECTOR="app.kubernetes.io/component=collector,app.kubernetes.io/name=tropis"
COLLECTOR_PORT=9476
KUBELET_CONDITIONS='["Ready","MemoryPressure","DiskPressure","PIDPressure","NetworkUnavailable"]'

# Fixed, not tunable: see docs/capture-rig.md 4.3, "Alert durations".
BASELINE_WAIT=900
MIN_AFTER_INJECT=120
SETTLE=60

usage() {
	echo "usage: $(basename "$0") [--dry-run] <scenario-id> <npd-absent|npd-present>" >&2
	exit 64
}

DRY=0
if [ "${1:-}" = --dry-run ]; then
	DRY=1
	shift
fi
[ "$#" -eq 2 ] || usage
ID="$1"
VARIANT="$2"
case "$VARIANT" in
npd-absent | npd-present) ;;
*) usage ;;
esac

# --- plan: everything here also runs in --dry-run ---------------------------

SCENARIO="$("$TROPIS_BIN" scenario show "$ID")" || die "cannot load scenario $ID"
eval "$SCENARIO"

has() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

case "$INJECT_SCRIPT" in
'' | pending-sectors.sh | degradation.sh | read-errors.sh | write-errors.sh | io-timeouts.sh | fs-corruption.sh | ephemeral-exhaustion.sh | containerd-kill.sh) ;;
*) die "$ID: no driver step for injection script $INJECT_SCRIPT" ;;
esac
TARGET_VAR=""
if [ -n "$INJECT_TARGET" ]; then
	case "$INJECT_SCRIPT" in
	pending-sectors.sh) TARGET_VAR=SECTORS ;;
	read-errors.sh) TARGET_VAR=BAD_BLOCKS ;;
	fs-corruption.sh) TARGET_VAR=VICTIM ;;
	*) die "$ID: no driver step to aim $INJECT_SCRIPT at a target" ;;
	esac
	case "$INJECT_TARGET" in
	postgres:*) [ "$WORKLOAD" = postgres-hostpath ] || die "$ID: target $INJECT_TARGET needs the postgres-hostpath workload" ;;
	/* | *..*) die "$ID: target $INJECT_TARGET must be relative to the mountpoint" ;;
	esac
fi
case "$SYMPTOM_SCRIPT" in
'' | silent-kill.sh) ;;
*) die "$ID: no driver step for symptom helper $SYMPTOM_SCRIPT" ;;
esac
for h in $HARDWARE; do
	case "$h" in
	real-sata | scarred-sata | smart-withheld) ;;
	*) die "$ID: no driver step for hardware $h" ;;
	esac
done
SMART_KEYS=""
for c in $EXPECT_SMART; do
	case "$c" in
	pending_sectors) SMART_KEYS="$SMART_KEYS pending" ;;
	reallocated_sectors) SMART_KEYS="$SMART_KEYS reallocated" ;;
	uncorrectable_errors) SMART_KEYS="$SMART_KEYS uncorrectable" ;;
	*) die "$ID: no driver check for expectSmart counter $c" ;;
	esac
done
MANIFEST="$REPO/eval/scenarios/workloads/$WORKLOAD.yaml"
[ -f "$MANIFEST" ] || die "$ID: no workload manifest $MANIFEST"
EXHAUSTION=0
[ "$INJECT_SCRIPT" = ephemeral-exhaustion.sh ] && EXHAUSTION=1
READ_PATH=0
case "$INJECT_SCRIPT" in pending-sectors.sh | degradation.sh | read-errors.sh) READ_PATH=1 ;; esac

MNT="$(inventory_field mountpoint)"
[ -n "$MNT" ] || die "the inventory gives no mountpoint for $TROPIS_NODE/$TROPIS_DISK"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN="$RUN_ROOT/$ID-$VARIANT-$STAMP"
[ "$DRY" = 1 ] && RUN="<run-dir>"
NOTES="kube-prometheus-stack 92.10.1 default rules; prometheus-smartctl-exporter 0.17.1 rules; hack/capture/baseline/smart-ata-rules.yaml; k8sgpt v0.4.40 analyze, core analyzers, no --explain; read $((BASELINE_WAIT / 60)) min after the symptom was confirmed"

# --- helpers -------------------------------------------------------------------

step() { echo; echo "== $*" >&2; }

# run CMD... runs a command, or prints it under --dry-run.
run() {
	if [ "$DRY" = 1 ]; then
		printf '+' && printf ' %q' "$@" && printf '\n'
	else
		"$@"
	fi
}

# run_to FILE CMD... sends a command's stdout to FILE (>> with APPEND=1).
run_to() {
	local file="$1"
	shift
	if [ "$DRY" = 1 ]; then
		printf '+' && printf ' %q' "$@" && printf ' %s %s\n' "$([ "${APPEND:-0}" = 1 ] && echo '>>' || echo '>')" "$file"
	elif [ "${APPEND:-0}" = 1 ]; then
		"$@" >>"$file"
	else
		"$@" >"$file"
	fi
}

# wait_until DESC TIMEOUT CMD... polls CMD until it succeeds, or fails the run.
wait_until() {
	local desc="$1" timeout="$2" waited=0
	shift 2
	if [ "$DRY" = 1 ]; then
		echo "wait: $desc (up to ${timeout}s)"
		return 0
	fi
	log "waiting: $desc"
	until "$@"; do
		[ "$waited" -lt "$timeout" ] || die "gave up after ${timeout}s waiting: $desc"
		sleep 10
		waited=$((waited + 10))
	done
	log "done: $desc"
	return 0
}

pause() {
	if [ "$DRY" = 1 ]; then
		echo "sleep: ${1}s, $2"
	else
		log "sleeping ${1}s: $2"
		sleep "$1"
	fi
	return 0
}

# ask QUESTION requires the operator to type "yes", or fails the run.
ask() {
	if [ "$DRY" = 1 ]; then
		echo "operator: $1"
		return 0
	fi
	local answer
	printf '\n%s\nType yes to continue, anything else to stop: ' "$1" >/dev/tty
	read -r answer </dev/tty || answer=""
	echo "operator answered: $answer"
	[ "$answer" = yes ] || die "stopped by the operator: $1"
	return 0
}

# confirm_token WANT has the operator type a script's confirmation.
confirm_token() {
	if [ "$DRY" = 1 ]; then
		echo "operator: type $1 to confirm"
		return 0
	fi
	local answer
	printf '\nType %s to confirm: ' "$1" >/dev/tty
	read -r answer </dev/tty || answer=""
	[ "$answer" = "$1" ] || die "confirmation $1 not given"
	return 0
}

k() { kubectl "$@"; }

npd_conditions() {
	k get node "$TROPIS_NODE" -o json |
		jq -c --argjson kubelet "$KUBELET_CONDITIONS" '[.status.conditions[] | select(.type as $t | $kubelet | index($t) | not)]'
}
npd_none() { [ "$(npd_conditions | jq length)" -eq 0 ]; }
npd_some() { [ "$(npd_conditions | jq length)" -gt 0 ]; }
npd_quiet() { npd_some && [ "$(npd_conditions | jq '[.[] | select(.status != "False")] | length')" -eq 0 ]; }

prom() { curl -fsS "http://127.0.0.1:$PROM_PORT$1"; }
prom_ready() { prom /-/ready >/dev/null 2>&1; }
no_eval_alerts() {
	[ "$(prom /api/v1/alerts | jq --arg ns "$NS" '[.data.alerts[] | select(.state == "firing" and .labels.namespace == $ns)] | length')" -eq 0 ]
}

collector_pod() {
	# The running pod on the node, never one still terminating after a restart.
	k -n "$COLLECTOR_NS" get pods -l "$COLLECTOR_SELECTOR" \
		--field-selector "spec.nodeName=$TROPIS_NODE,status.phase=Running" -o json |
		jq -er '[.items[] | select(.metadata.deletionTimestamp == null)][0].metadata.name'
}
# collector_reading prints the collectedAt of the collector's current reading.
collector_reading() {
	local pod
	pod="$(collector_pod)" && [ -n "$pod" ] &&
		k get --raw "/api/v1/namespaces/$COLLECTOR_NS/pods/$pod:$COLLECTOR_PORT/proxy/v1/smart" | jq -er .collectedAt
}
collector_has_reading() { collector_reading >/dev/null 2>&1; }
# collector_age_secs prints how long the collector container has run: its
# SMART history lives in memory, so a container restart loses it too.
collector_age_secs() {
	local started
	started="$(k -n "$COLLECTOR_NS" get pod "$(collector_pod)" -o json | jq -er '.status.containerStatuses[0].state.running.startedAt')" ||
		die "cannot read the collector container's start time"
	echo $(($(date -u +%s) - $(date -u -d "$started" +%s)))
}

pods_started() {
	k -n "$NS" get pods -o json | jq -e '
		(.items | length) > 0 and all(.items[];
			.status.phase == "Succeeded" or .status.phase == "Failed" or
			((.status.containerStatuses // []) | length > 0 and
				all(.[]; .state.running or .state.terminated or .lastState.terminated)))' >/dev/null
}
pod_evicted() {
	k -n "$NS" get pods -o json | jq -e 'any(.items[]; .status.reason == "Evicted")' >/dev/null
}
disk_pressure_false() {
	[ "$(k get node "$TROPIS_NODE" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False ]
}

# counter KEY SNAPSHOT prints one count from a smart_snapshot line.
counter() { printf '%s\n' "$2" | sed -n "s/.*$1=\([0-9][0-9]*\).*/\1/p"; }
# smart_raised: an expectSmart counter is above its value in the start record.
smart_raised() {
	local before now key b n
	before="$(jq -r '.injection.params.smartBefore // ""' "$RUN/fault.json")"
	now="$(smart_snapshot)"
	for key in $SMART_KEYS; do
		b="$(counter "$key" "$before")"
		n="$(counter "$key" "$now")"
		if [ -n "$b" ] && [ -n "$n" ] && [ "$n" -gt "$b" ]; then
			log "$key: $b -> $n"
			return 0
		fi
	done
	log "no expectSmart counter has risen yet: before '$before', now '$now'"
	return 1
}

kills_delivered() {
	local want n
	want="$(printf '%s\n' $SYMPTOM_PARAMS | sed -n 's/^KILLS=//p')"
	n="$("$SYMPTOMS/$SYMPTOM_SCRIPT" status 2>/dev/null | sed -n 's/.*active, \([0-9]*\) kills.*/\1/p')"
	[ -n "$n" ] && [ "$n" -ge "${want:-3}" ]
}

target_ready() {
	case "$INJECT_TARGET" in
	postgres:*) [ -n "$(postgres_file 2>/dev/null)" ] ;;
	*'*'*) [ -n "$(newest_match)" ] ;;
	*)
		local f="$MNT/$INJECT_TARGET" a b
		[ -s "$f" ] || return 1
		a="$(stat -c %s "$f")"
		sleep 10
		b="$(stat -c %s "$f")"
		[ "$a" = "$b" ]
		;;
	esac
}
# postgres_file prints the host path of the target table's file.
postgres_file() {
	local table="${INJECT_TARGET#postgres:}" pod rel
	pod="$(k -n "$NS" get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
	rel="$(k -n "$NS" exec "$pod" -c postgres -- psql -U postgres -Atc "select pg_relation_filepath('$table')")" || return 1
	# postgres-hostpath mounts $MNT/postgres at /var/lib/postgresql/data, with PGDATA in pgdata/.
	[ -n "$rel" ] && [ -s "$MNT/postgres/pgdata/$rel" ] && echo "$MNT/postgres/pgdata/$rel"
}
# newest_match prints the most recently modified file matching the target glob.
newest_match() {
	local f best="" bt=0 t
	for f in $MNT/$INJECT_TARGET; do
		[ -s "$f" ] || continue
		t="$(stat -c %Y "$f")"
		if [ "$t" -ge "$bt" ]; then
			best="$f"
			bt="$t"
		fi
	done
	echo "$best"
}
target_file() {
	case "$INJECT_TARGET" in
	postgres:*) postgres_file ;;
	*'*'*) newest_match ;;
	*) echo "$MNT/$INJECT_TARGET" ;;
	esac
}

no_fault_active() {
	local s
	for s in pending-sectors degradation read-errors write-errors io-timeouts fs-corruption ephemeral-exhaustion containerd-kill; do
		"$INJECT/$s.sh" status >/dev/null 2>&1 && { log "$s is still active"; return 1; }
	done
	"$SYMPTOMS/silent-kill.sh" status >/dev/null 2>&1 && { log "silent-kill is still active"; return 1; }
	return 0
}

# passthrough_on_target checks the dm device is the plain pass-through onto
# the inventory's target, so mkfs can only ever reach the destructible disk.
passthrough_on_target() {
	local table start kind dev offset want
	table="$(dmsetup table "$DM_NAME")" || return 1
	[ "$(printf '%s\n' "$table" | wc -l)" -eq 1 ] || return 1
	read -r start _ kind dev offset _ <<<"$table"
	want="$(lsblk -dnro MAJ:MIN "$TARGET" | tr -d ' ')"
	[ "$start" = 0 ] && [ "$kind" = linear ] && [ "$dev" = "$want" ] && [ "$offset" = 0 ]
}

# --- cleanup: undo whatever was started, on any exit ---------------------------

CLEANUP=()
on_exit() {
	local rc=$? i
	set +e
	for ((i = ${#CLEANUP[@]} - 1; i >= 0; i--)); do
		log "cleanup: ${CLEANUP[$i]}"
		eval "${CLEANUP[$i]}"
	done
	if [ "$DRY" = 0 ]; then
		[ "$rc" -eq 0 ] && log "finished; records in $RUN" || log "FAILED (exit $rc); records in $RUN. A failure is a setup failure: fix it and retake."
	fi
	exit "$rc"
}
trap on_exit EXIT

# cleanup_add CMD registers a command for on_exit; --dry-run only prints it.
cleanup_add() {
	if [ "$DRY" = 1 ]; then
		echo "on exit: $1"
	else
		CLEANUP+=("$1")
	fi
	return 0
}

# --- preflight -----------------------------------------------------------------

step "$ID ($VARIANT) on $TROPIS_NODE/$TROPIS_DISK"
echo "scenario: $SCENARIO_DESCRIPTION"
if [ "$DRY" = 0 ]; then
	require_root
	require_cmd kubectl jq curl envsubst smartctl dmsetup mkfs.ext4 findmnt lsblk stat "$K8SGPT"
	resolve_target
	require_prepared
	mkdir -p "$RUN_ROOT"
	root_real="$(cd "$RUN_ROOT" && pwd -P)"
	corpus_real="$(cd "$CORPUS" && pwd -P)" || die "no corpus directory $CORPUS"
	case "$root_real/" in
	"$corpus_real"/*) die "TROPIS_RUN_ROOT $RUN_ROOT is inside the corpus; run records never go in $CORPUS" ;;
	esac
	mkdir -p "$RUN"
	exec > >(tee -a "$RUN/run.log") 2>&1
	printf '%s\n' "$SCENARIO" >"$RUN/scenario.env"
	{
		echo "started: $(now)"
		echo "variant: $VARIANT"
		echo "tropis: $("$TROPIS_BIN" version 2>&1)"
		echo "k8sgpt: $("$K8SGPT" version 2>&1 | head -n1)"
		echo "npd image: $(k -n kube-system get daemonset node-problem-detector -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo none)"
		echo "helm releases:"
		helm list -A 2>/dev/null || echo "  (helm not available)"
	} >"$RUN/versions.txt"
	wait_until "no fault or symptom helper active" 0 no_fault_active
fi

step "Prometheus port-forward"
if [ "$DRY" = 1 ]; then
	echo "+ kubectl -n monitoring port-forward svc/prometheus-operated $PROM_PORT:9090 &"
else
	kubectl -n monitoring port-forward svc/prometheus-operated "$PROM_PORT:9090" >"$RUN/port-forward.log" 2>&1 &
	CLEANUP+=("kill $! 2>/dev/null")
fi
wait_until "Prometheus answering on :$PROM_PORT" 60 prom_ready

# --- variant -------------------------------------------------------------------

step "NPD variant: $VARIANT"
if [ "$VARIANT" = npd-absent ]; then
	if [ "$DRY" = 0 ]; then
		k -n kube-system get daemonset node-problem-detector >/dev/null 2>&1 &&
			die "node-problem-detector is installed; uninstall it and clear its conditions (capture-rig.md 4.7, Switching variant)"
	fi
	wait_until "no NPD conditions on $TROPIS_NODE" 0 npd_none
else
	run kubectl -n kube-system rollout status daemonset node-problem-detector --timeout=5m
	# A permanent condition from the last scenario must not reach this fixture.
	if [ "$DRY" = 1 ] || ! npd_quiet; then
		echo "NPD conditions: $([ "$DRY" = 1 ] && echo '<from node>' || npd_conditions)"
		run kubectl -n kube-system rollout restart daemonset node-problem-detector
		run kubectl -n kube-system rollout status daemonset node-problem-detector --timeout=5m
	fi
	wait_until "every NPD condition on $TROPIS_NODE present and False" 900 npd_quiet
fi

# --- reset ---------------------------------------------------------------------

step "reset"
run kubectl delete namespace "$NS" --wait --ignore-not-found
if [ "$DRY" = 0 ]; then
	passthrough_on_target || die "$(dm_path) is not the plain pass-through onto $TARGET; stop the fault or re-run prepare.sh"
	if findmnt -n --mountpoint "$MNT" >/dev/null; then umount "$MNT"; fi
fi
run mkfs.ext4 -q -F "$(dm_path)"
run mkdir -p "$MNT"
run mount -o errors=remount-ro "$(dm_path)" "$MNT"
wait_until "no firing alert in namespace $NS (the last scenario's)" 900 no_eval_alerts

if has "$HARDWARE" scarred-sata; then
	# The stable-defect check compares against the collector's oldest
	# reading, which must be a day old; capture cannot check its age.
	if [ "$DRY" = 1 ]; then
		echo "check: collector on $TROPIS_NODE running for at least 24 h"
	else
		age="$(collector_age_secs)"
		[ "$age" -ge 86400 ] || die "the collector has run $((age / 3600)) h; scarred-sata scenarios need 24 h of history (capture-rig.md 4.7)"
	fi
fi
if has "$HARDWARE" real-sata; then
	# Capture compares the drive with the collector's oldest reading, which
	# must be from before the fault.
	run kubectl -n "$COLLECTOR_NS" rollout restart daemonset "$COLLECTOR_DS"
	run kubectl -n "$COLLECTOR_NS" rollout status daemonset "$COLLECTOR_DS" --timeout=5m
	wait_until "the restarted collector's first (pre-fault) reading" 300 collector_has_reading
	[ "$DRY" = 0 ] && echo "collector pre-fault reading: $(collector_reading)"
fi
if has "$HARDWARE" smart-withheld; then
	# Undo below reverts one revision, so the patch must be a real change.
	if [ "$DRY" = 0 ] && [ "$(k -n "$COLLECTOR_NS" get daemonset "$COLLECTOR_DS" \
		-o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsUser}')" = 65534 ]; then
		die "the collector already runs as 65534: undo the earlier patch (rollout undo) and check it is back to root first"
	fi
	run kubectl -n "$COLLECTOR_NS" patch daemonset "$COLLECTOR_DS" --type=json \
		-p '[{"op":"replace","path":"/spec/template/spec/containers/0/securityContext/runAsUser","value":65534}]'
	cleanup_add "kubectl -n $COLLECTOR_NS rollout undo daemonset $COLLECTOR_DS && kubectl -n $COLLECTOR_NS rollout status daemonset $COLLECTOR_DS --timeout=5m && echo collector runAsUser: \$(kubectl -n $COLLECTOR_NS get daemonset $COLLECTOR_DS -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsUser}')"
	run kubectl -n "$COLLECTOR_NS" rollout status daemonset "$COLLECTOR_DS" --timeout=5m
	wait_until "the collector's first reading as a non-root user" 300 collector_has_reading
fi

# --- fault and workload --------------------------------------------------------

start_fault() {
	local -a envs=()
	# shellcheck disable=SC2206 # params are NAME=value words, validated by tropis
	envs=($INJECT_PARAMS)
	if [ -n "$TARGET_VAR" ]; then
		local file val out SECTORS BAD_BLOCKS
		if [ "$DRY" = 1 ]; then
			file="<file for $INJECT_TARGET>"
		else
			file="$(target_file)"
			[ -f "$file" ] || die "target $INJECT_TARGET resolved to '$file', not a file"
		fi
		echo "target: $file"
		if [ "$TARGET_VAR" = VICTIM ]; then
			val="$file"
		elif [ "$DRY" = 1 ]; then
			run "$INJECT/target-blocks.sh" "$file"
			val="<from target-blocks.sh>"
		else
			out="$("$INJECT/target-blocks.sh" "$file")" || die "target-blocks.sh refused $file"
			# shellcheck disable=SC2034 # set by the eval, read through ${!TARGET_VAR}
			SECTORS="" BAD_BLOCKS=""
			eval "$out"
			val="${!TARGET_VAR}"
		fi
		envs+=("$TARGET_VAR=$val")
	fi
	local confirm="${TROPIS_INJECT_CONFIRM:-$TROPIS_NODE/$TROPIS_DISK}"
	if [ "$INJECT_SCRIPT" = containerd-kill.sh ]; then
		confirm="$TROPIS_NODE/containerd"
		confirm_token "$confirm"
	fi
	run_to "$RUN/fault.json" env "${envs[@]}" TROPIS_INJECT_CONFIRM="$confirm" "$INJECT/$INJECT_SCRIPT" start
	cleanup_add "TROPIS_INJECT_CONFIRM='$confirm' '$INJECT/$INJECT_SCRIPT' stop >'$RUN/fault-stop.json'"
	FAULT_AT="$(date -u +%s)"
	return 0
}

apply_workload() {
	if [ "$DRY" = 1 ]; then
		echo "+ TROPIS_NODE=$TROPIS_NODE TROPIS_MOUNT=$MNT envsubst '\${TROPIS_NODE} \${TROPIS_MOUNT}' < $MANIFEST | kubectl apply -f -"
	else
		TROPIS_MOUNT="$MNT" envsubst '${TROPIS_NODE} ${TROPIS_MOUNT}' <"$MANIFEST" | kubectl apply -f -
	fi
	wait_until "every pod in $NS started" 600 pods_started
	return 0
}

FAULT_AT=""
if [ "$EXHAUSTION" = 1 ]; then
	# The workload is the fault: the script checks the node first.
	step "inject: $INJECT_SCRIPT (before the workload)"
	start_fault
	step "workload: $WORKLOAD"
	apply_workload
else
	step "workload: $WORKLOAD"
	apply_workload
	pause "$SETTLE" "let the workload reach steady state"
	if [ -n "$INJECT_SCRIPT" ]; then
		step "inject: $INJECT_SCRIPT ${INJECT_PARAMS:+($INJECT_PARAMS)}${INJECT_TARGET:+, aimed at $INJECT_TARGET}"
		[ -n "$INJECT_TARGET" ] && wait_until "target $INJECT_TARGET written" 600 target_ready
		start_fault
		if [ "$READ_PATH" = 1 ]; then
			run sync
			run_to /proc/sys/vm/drop_caches echo 3
		fi
	fi
fi

if [ -n "$SYMPTOM_SCRIPT" ]; then
	step "symptom: $SYMPTOM_SCRIPT ($SYMPTOM_PARAMS)"
	confirm_token "$TROPIS_NODE/silent-kill"
	# shellcheck disable=SC2086
	APPEND=1 run_to "$RUN/symptom.jsonl" env $SYMPTOM_PARAMS TROPIS_INJECT_CONFIRM="$TROPIS_NODE/silent-kill" "$SYMPTOMS/$SYMPTOM_SCRIPT" start
	cleanup_add "'$SYMPTOMS/$SYMPTOM_SCRIPT' stop >>'$RUN/symptom.jsonl'"
	wait_until "every silent kill delivered" 1800 kills_delivered
fi

# --- wait for the symptom ----------------------------------------------------------

automated_checks() {
	[ -n "$SMART_KEYS" ] && wait_until "an expectSmart counter ($EXPECT_SMART) above smartBefore" "${1:-3600}" smart_raised
	if [ "$EXHAUSTION" = 1 ]; then
		wait_until "a pod in $NS evicted" "${1:-600}" pod_evicted
		wait_until "DiskPressure False on $TROPIS_NODE (an eviction under no node pressure)" 0 disk_pressure_false
	fi
	return 0
}

show_state() {
	[ "$DRY" = 1 ] && { echo "show: pods, last states and recent events in $NS"; return 0; }
	kubectl -n "$NS" get pods -o wide
	kubectl -n "$NS" get pods -o json | jq -r '.items[] | .metadata.name as $p | .status.containerStatuses[]? |
		"\($p)/\(.name): restarts \(.restartCount), last \(.lastState.terminated.reason // "-") exit \(.lastState.terminated.exitCode // "-")"'
	kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 15
	if [ -n "$INJECT_SCRIPT" ]; then "$INJECT/$INJECT_SCRIPT" status || true; fi
	return 0
}

step "symptom"
if [ -n "$FAULT_AT" ] && [ "$DRY" = 0 ]; then
	left=$((FAULT_AT + MIN_AFTER_INJECT - $(date -u +%s)))
	[ "$left" -gt 0 ] && pause "$left" "at least ${MIN_AFTER_INJECT}s after injecting"
else
	pause "$MIN_AFTER_INJECT" "at least ${MIN_AFTER_INJECT}s after injecting"
fi
automated_checks
show_state
ask "Scenario $ID: $SCENARIO_DESCRIPTION
Is that symptom present now (pods, events and logs above; kubectl logs for more)?"

step "baseline wait"
pause "$BASELINE_WAIT" "let the incumbent's alerts reach their for: durations (capture-rig.md 4.3)"
automated_checks 0
show_state
ask "After the baseline wait: is the symptom still present?"

# --- baseline and capture ------------------------------------------------------------

step "baseline"
run_to "$RUN/alerts.json" curl -fsS "http://127.0.0.1:$PROM_PORT/api/v1/alerts"
run_to "$RUN/k8sgpt.yaml" echo 'active_filters: []'
run_to "$RUN/k8sgpt.txt" "$K8SGPT" --config "$RUN/k8sgpt.yaml" analyze --namespace "$NS" --no-cache --output text

step "capture"
args=(capture --scenario "$ID" --variant "$VARIANT" --node "$TROPIS_NODE" --disk "$TROPIS_DISK"
	--inventory "$TROPIS_INVENTORY" --corpus "$CORPUS"
	--prometheus "http://127.0.0.1:$PROM_PORT" --k8sgpt-file "$RUN/k8sgpt.txt" --baseline-notes "$NOTES")
[ -n "$INJECT_SCRIPT" ] && args+=(--injection "$RUN/fault.json")
[ "${RETAKE:-0}" = 1 ] && args+=(--force)
run "$TROPIS_BIN" "${args[@]}"

step "stop"
# The fault and symptom helper stop in on_exit, which runs on failure too.
exit 0
