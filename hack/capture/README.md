# Capture-rig tooling

What the capture run in [docs/capture-rig.md](../../docs/capture-rig.md)
uses besides the injection scripts. Nothing here ships in a binary or the
chart.

| Path | What |
|---|---|
| `run-scenario.sh` | The capture driver: one scenario, one NPD variant, start to finish (run book 4.7) |
| `test.sh` | Dry-runs the driver over every scenario in both variants; `make capture-test`, part of `make check` |
| `npd/` | Stock node-problem-detector, pinned, for the `npd-present` variant (run book 4.3) |
| `baseline/` | The incumbent baseline: kube-prometheus-stack and smartctl-exporter values, and the SATA SMART alert rules (run book 4.3) |

## The driver

```sh
export TROPIS_INVENTORY=rig.yaml TROPIS_NODE=worker-02 TROPIS_DISK=clean
export TROPIS_INJECT_CONFIRM=worker-02/clean
hack/capture/run-scenario.sh --dry-run read-errors-batch npd-absent   # the plan, nothing run
sudo -E hack/capture/run-scenario.sh read-errors-batch npd-absent
```

It runs on the capture worker as root, from a checkout, with the drive
already set up as in run book 4.6 (`prepare.sh start`), NPD installed or
not to match the variant, and a kubeconfig that can reach the cluster. It
reads the scenario with `tropis scenario show`, so `tropis` must be the
release being captured with: the scenarios come from that binary.

In order, it:

1. checks the variant against the cluster (NPD absent with no conditions on
   the node, or present with every condition `False`, restarting NPD to
   clear a permanent one), and that no fault or symptom helper is active;
2. resets: deletes `tropis-eval`, checks `/dev/mapper/tropis-target` is
   the plain pass-through onto the inventory's target, mkfs and remounts
   it, and waits for the last scenario's alerts to resolve; for
   `real-sata` it restarts the collector and waits for its first,
   pre-fault reading; for `scarred-sata` it refuses unless the collector
   has run 24 h; for `smart-withheld` it patches the collector to run as
   65534 and undoes that on exit;
3. applies the workload, then injects (exhaustion scenarios the other way
   round), aiming the fault with `target-blocks.sh` or `VICTIM` where the
   scenario has an `inject.target`, and drops the page cache for read-path
   faults;
4. starts the scenario's symptom helper and waits for every kill;
5. waits 2 minutes and for what it can check (an `expectSmart` counter
   above the start record's `smartBefore`; for exhaustion, a pod evicted
   and `DiskPressure` `False`), shows the pods and events, and asks the
   operator to type `yes` if the scenario's symptom is there;
6. holds the fault 15 minutes for the baseline, checks and asks again;
7. saves Prometheus's alerts and `k8sgpt` output, runs `tropis capture`
   with `--baseline-notes`, and stops the fault and helper, on failure too.

The containerd and silent-kill confirmations are typed at a prompt each
time. A capture refusal ends the run; `--force` is passed only with
`RETAKE=1`, for a retake decided before anyone looked at a verdict.

Records go to `$TROPIS_RUN_ROOT/<scenario>-<variant>-<time>/` (default
`/var/lib/tropis-capture/runs`, and never inside the corpus): `run.log`,
`scenario.env`, `versions.txt`, `fault.json`, `fault-stop.json`,
`symptom.jsonl`, `alerts.json`, `k8sgpt.txt`.
