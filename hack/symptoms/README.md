# Symptom helpers

Scripts that produce a *symptom* on the capture rig rather than a fault.
A fault script in [hack/inject](../inject/README.md) prints the record that
becomes the fixture's `label.json` injection; a symptom helper does not.
Its record starts with `"symptom"`, belongs in the run log only, and must
never be passed to `tropis capture --injection` (which would refuse it).

| Script | Symptom | Mechanism |
|---|---|---|
| `silent-kill.sh` | a container killed with exit 137, with no log or event saying why | SIGKILL to the container's main process from the host, found through `crictl` |

## silent-kill.sh

For `pending-silent-137` and `unreadable-smart-restarts`, with the
`batch-reader-silent` workload, which writes nothing to stdout or stderr
and neither prints nor exits on a failed read. Run on the node, as root,
with `crictl` and `jq` installed:

```sh
export TROPIS_INVENTORY=rig.yaml TROPIS_NODE=worker-02
TROPIS_INJECT_CONFIRM=worker-02/silent-kill APP=batch-reader KILLS=3 INTERVAL=60 \
  hack/symptoms/silent-kill.sh start >> run-log.jsonl
hack/symptoms/silent-kill.sh status   # "active, 3 kills delivered" when done
# ... capture ...
hack/symptoms/silent-kill.sh stop >> run-log.jsonl
```

The first kill happens in `start`, the rest in the background, each waiting
up to `WAIT_RUNNING` seconds (default 300) for the kubelet to restart the
container. Because the kill comes from outside and not from the kernel's
OOM killer or the kubelet, the container's last state is `Error`, exit
code 137, and there is no `OOMKilled` reason and no `Killing` event. The
kubelet's ordinary restart events (`Pulled`, `Created`, `Started`, and
`BackOff` between quick restarts) still appear: they are unavoidable on any
restart, and say nothing about the cause.

It refuses unless `TROPIS_INJECT_CONFIRM` is `<node>/silent-kill`, the node
is in the inventory, and the target is exactly one ready pod sandbox in
namespace `tropis-eval` labelled `tropis.io/eval=true` and `app=$APP`, with
exactly one running container (or the one named `CONTAINER`). The
namespace and labels are checked on `crictl inspectp`/`inspect` output
before every kill, not only through `crictl`'s filters.

`make inject-test` covers it with a fake `crictl`: the kill and its exit
status 137, repeated kills, both records, and the refusals.
