#!/usr/bin/env bash
# Kill an eval workload's container silently: SIGKILL its main process from
# the host, so it ends with exit 137 and nothing inside it says why.
#
# A symptom, not a fault. The scenarios that need it (pending-silent-137,
# unreadable-smart-restarts) want a container killed with exit 137 leaving no
# logs and no event that explains the kill: not OOMKilled (the kernel's OOM
# killer is not involved, so the kubelet reports reason Error), and no
# Killing event (the kubelet did not ask for it). What the kubelet does emit
# on any restart (Pulled, Created, Started and, between quick restarts,
# BackOff) is unavoidable and explains nothing. Pair it with the silent
# workload, batch-reader-silent, which writes nothing to stdout or stderr.
#
# It writes no fault record for label.json: its record starts with
# "symptom", not "faultType", and belongs in the run log only. Never pass it
# to `tropis capture --injection`, which would refuse it anyway.
#
#   silent-kill.sh start    first kill now, the rest in the background
#   silent-kill.sh stop     stop the background kills; print the record
#   silent-kill.sh status
#
# The target is found through the CRI (crictl) and must be a pod sandbox in
# namespace tropis-eval carrying the label tropis.io/eval=true and
# app=$APP, with exactly one running container (or the one named
# $CONTAINER). Anything else is refused, checked on crictl's inspect output
# before every kill, not only by its filters.
#
# Confirmation is TROPIS_INJECT_CONFIRM="$TROPIS_NODE/silent-kill".
#
# Parameters:
#   APP        the pod's app label (required), e.g. batch-reader
#   CONTAINER  container name (default: the pod's only running container)
#   KILLS      number of kills (default 3)
#   INTERVAL   seconds between kills (default 60); the next kill waits up to
#              WAIT_RUNNING seconds (default 300) for the container to be
#              running again after the kubelet's restart back-off
#   TROPIS_CRICTL  crictl binary (default crictl on PATH)
. "$(dirname "$0")/../inject/lib.sh"

SYMPTOM=silent-kill
NAMESPACE=tropis-eval
CRICTL="${TROPIS_CRICTL:-crictl}"

# emit_symptom STARTED ENDED KEY=VALUE... prints the run-log record.
emit_symptom() {
	local started="$1" ended="$2"
	shift 2
	local params="" kv
	for kv in "$@"; do
		[ -n "$params" ] && params="$params,"
		params="$params\"$(json_escape "${kv%%=*}")\":\"$(json_escape "${kv#*=}")\""
	done
	printf '{"symptom":"container.silent_kill","node":"%s","params":{%s},"startedAt":"%s"' \
		"$(json_escape "${NODE:-$TROPIS_NODE}")" "$params" "$started"
	[ -n "$ended" ] && printf ',"endedAt":"%s"' "$ended"
	printf '}\n'
}

# resolve prints "<container id> <pid>" for the target's running container,
# or fails saying why. Every claim crictl's filters make is checked again on
# its inspect output.
resolve() {
	local pods pod podjson ctrs ctr ctrjson pid
	pods="$("$CRICTL" pods --namespace "$NAMESPACE" --label tropis.io/eval=true --label "app=$APP" --state ready -q)" ||
		{ log "crictl pods failed"; return 1; }
	# shellcheck disable=SC2086 # word splitting of the id list is intended
	set -- $pods
	[ "$#" -eq 1 ] || { log "want exactly one ready pod with app=$APP in $NAMESPACE, found $#"; return 1; }
	pod="$1"
	podjson="$("$CRICTL" inspectp -o json "$pod")" || { log "crictl inspectp $pod failed"; return 1; }
	printf '%s' "$podjson" | jq -e --arg ns "$NAMESPACE" --arg app "$APP" \
		'.status.metadata.namespace == $ns and .status.labels["tropis.io/eval"] == "true" and .status.labels.app == $app' >/dev/null ||
		{ log "refusing: pod sandbox $pod is not in $NAMESPACE with tropis.io/eval=true and app=$APP"; return 1; }

	if [ -n "${CONTAINER:-}" ]; then
		ctrs="$("$CRICTL" ps --pod "$pod" --state running --name "^$CONTAINER\$" -q)"
	else
		ctrs="$("$CRICTL" ps --pod "$pod" --state running -q)"
	fi || { log "crictl ps failed"; return 1; }
	# shellcheck disable=SC2086
	set -- $ctrs
	[ "$#" -eq 1 ] || { log "want exactly one running container${CONTAINER:+ named $CONTAINER} in pod $pod, found $#"; return 1; }
	ctr="$1"
	ctrjson="$("$CRICTL" inspect -o json "$ctr")" || { log "crictl inspect $ctr failed"; return 1; }
	printf '%s' "$ctrjson" | jq -e --arg ns "$NAMESPACE" --arg pod "$pod" \
		'.status.labels["io.kubernetes.pod.namespace"] == $ns and (.info.sandboxID // $pod) == $pod' >/dev/null ||
		{ log "refusing: container $ctr is not in $NAMESPACE pod $pod"; return 1; }
	pid="$(printf '%s' "$ctrjson" | jq -r '.info.pid // empty')"
	case "$pid" in
	'' | *[!0-9]*) log "container $ctr has no pid"; return 1 ;;
	esac
	[ "$pid" -gt 1 ] && [ -d "/proc/$pid" ] || { log "container $ctr pid $pid is not a live host process"; return 1; }
	echo "$ctr $pid"
}

# kill_once SIGKILLs the target's main process and records the container.
kill_once() {
	local target ctr pid
	target="$(resolve)" || return 1
	read -r ctr pid <<<"$target"
	kill -KILL "$pid" || return 1
	log "killed container $ctr (pid $pid)"
	echo "$ctr" >>"$STATE_DIR/$SYMPTOM.killed"
}

worker() {
	state_load "$SYMPTOM"
	local i=1 waited
	while [ "$i" -lt "$KILLS" ] && state_active "$SYMPTOM"; do
		sleep "$INTERVAL"
		# After a kill the kubelet restarts the container, with back-off.
		waited=0
		until kill_once 2>/dev/null; do
			[ "$waited" -lt "$WAIT_RUNNING" ] && state_active "$SYMPTOM" || return 0
			sleep 5
			waited=$((waited + 5))
		done
		i=$((i + 1))
	done
	return 0
}

case "${1:-}" in
start)
	require_root
	require_cmd "$CRICTL" jq setsid
	[ -n "${TROPIS_INVENTORY:-}" ] && [ -n "${TROPIS_NODE:-}" ] || die "TROPIS_INVENTORY and TROPIS_NODE are required"
	[ -n "${APP:-}" ] || die "APP is required: the target pod's app label"
	confirm "$TROPIS_NODE/$SYMPTOM"
	"$TROPIS_BIN" inventory node --inventory "$TROPIS_INVENTORY" --node "$TROPIS_NODE" >/dev/null ||
		die "node $TROPIS_NODE is not in the inventory"
	state_active "$SYMPTOM" && die "$SYMPTOM is already active"

	kills="${KILLS:-3}"
	interval="${INTERVAL:-60}"
	wait_running="${WAIT_RUNNING:-300}"
	mkdir -p "$STATE_DIR"
	rm -f "$STATE_DIR/$SYMPTOM.killed"
	started="$(now)"
	kill_once || die "nothing killed"

	state_save "$SYMPTOM" "STARTED=$started" "KILLS=$kills" "INTERVAL=$interval" \
		"WAIT_RUNNING=$wait_running" "APP=$APP" "CONTAINER=${CONTAINER:-}" "NODE=$TROPIS_NODE"
	if [ "$kills" -gt 1 ]; then
		setsid "$0" _worker </dev/null >/dev/null 2>&1 &
		echo $! >"$STATE_DIR/$SYMPTOM.pid"
	fi
	emit_symptom "$started" "" "namespace=$NAMESPACE" "app=$APP" "container=${CONTAINER:-}" \
		"signal=SIGKILL" "kills=$kills" "intervalSecs=$interval"
	;;
_worker)
	worker
	;;
stop)
	require_root
	state_load "$SYMPTOM"
	if [ -f "$STATE_DIR/$SYMPTOM.pid" ]; then
		kill "$(cat "$STATE_DIR/$SYMPTOM.pid")" 2>/dev/null || true
	fi
	killed="$(tr '\n' ' ' <"$STATE_DIR/$SYMPTOM.killed" 2>/dev/null || true)"
	killed="${killed% }"
	delivered="$(wc -w <<<"$killed" | tr -d ' ')"
	ended="$(now)"
	state_clear "$SYMPTOM"
	rm -f "$STATE_DIR/$SYMPTOM.pid" "$STATE_DIR/$SYMPTOM.killed"
	emit_symptom "$STARTED" "$ended" "namespace=$NAMESPACE" "app=$APP" "container=$CONTAINER" \
		"signal=SIGKILL" "kills=$KILLS" "killsDelivered=$delivered" "intervalSecs=$INTERVAL" \
		"containersKilled=$killed"
	;;
status)
	if state_active "$SYMPTOM"; then
		echo "$SYMPTOM: active, $(cat "$STATE_DIR/$SYMPTOM.killed" 2>/dev/null | wc -l | tr -d ' ') kills delivered"
	else
		echo "$SYMPTOM: inactive"
		exit 1
	fi
	;;
*) usage_exit ;;
esac
