# Capture rig plan

How to buy and build the rig, and then run the capture that produces
`eval/fixtures/`, the corpus behind Tropis's published accuracy numbers.
Nothing synthetic may enter that directory, and nothing here relaxes that
rule.

Read with: [eval/README.md](../eval/README.md) (metrics and gate),
[hack/inject/README.md](../hack/inject/README.md) (injection and safety),
[docs/inventory.md](inventory.md), [docs/fixtures.md](fixtures.md) and
[`eval/scenarios/scenarios.yaml`](../eval/scenarios/scenarios.yaml).

## 1. What the rig must produce

`scenarios.yaml` holds 30 scenarios. Each is captured once per NPD variant,
so the job is **60 fixtures**: one `fixture.json` + `label.json` per
`<scenario>-<variant>` directory.

| Expected | Scenarios | Fixtures (×2 variants) | Of which need real SMART movement |
|---|---|---|---|
| `causal`, host, SMART-visible (`real-sata`) | 8 | 16 | 16 |
| `causal`, host, SMART clean (device-mapper) | 10 | 20 | 0 |
| `causal`, Kubernetes (ephemeral-storage exhaustion) | 2 | 4 | 0 |
| **Positives** | **20** | **40** | 16 |
| `coincidental` (negative controls) | 6 | 12 | 2 |
| `insufficient_evidence` | 4 | 8 | 6 |
| **Total** | **30** | **60** | 24 |

What the gate needs (`eval/runner/metrics.go`, computed over both variants
pooled):

| Gate term | Threshold | On the full corpus |
|---|---|---|
| Positives | ≥ 20 | 40 |
| End-to-end detection | ≥ 80% | ≥ 32 of 40 raised *and* correct |
| False-correlation rate | < 10% | at most 1 of 12 negative-control fixtures called `causal` (2 is 16.7%) |

- **Captures per scenario: exactly two**, one `npd-absent` and one
  `npd-present`. The fixture directory has one slot per variant; there are
  no repeats to average. `--force` replaces a capture.
- **Retake only for a setup failure** (symptom never appeared, wrong
  workload, refused capture, clock wrong), decided *before* anyone looks
  at a verdict. Never run `tropis analyze` or `tropis eval` on a capture to
  decide whether to keep it: that is selecting the corpus on the result.
- **Capture all 30.** The bare minimum to make the gate applicable is 20
  positive fixtures, but the published number is meant to rest on ≥ 20
  scenarios in both variants, and the 18 non-positive scenarios are what
  make the false-correlation rate and the `coincidental` /
  `insufficient_evidence` behaviour mean anything.
- The margin is thin. The 4 `io-timeout-*` fixtures are a known miss (not
  raised unless SMART moves; eval/README.md, *Known gap*), leaving at most
  4 further misses among the other 36 positives.

## 2. Hardware

### Shape

Three nodes, as the build brief specifies: one control plane, one bystander
worker, one **capture worker** that holds the test disk. Only the capture
worker needs anything special. No BMC is needed: the inventory's `bmc` block
is unused until Phase 6, so do not pay for one.

| Node | Role | Needs |
|---|---|---|
| `cp-01` | control plane | Any x86-64, 4 cores, 8–16 GB, SSD boot. A used 1-litre business mini PC is ideal |
| `worker-01` | bystander worker; runs the Prometheus baseline stack | As above, 16 GB (kube-prometheus-stack wants 2–4 GB) |
| `worker-02` | capture worker | Used business **micro-tower** (not SFF/micro): Intel 8th/9th gen i5, 16 GB, an **M.2 NVMe slot for the boot disk**, ≥ 2 onboard SATA ports in **AHCI** mode, SATA power for ≥ 2 drives, room for a 3.5" drive |

Capture-worker rules:

- **Onboard SATA in AHCI mode.** Many Dell/HP desktops ship with "RAID On"
  / Intel RST: switch to AHCI in the firmware *before* installing the OS.
  No RAID HBA, no SAS HBA, no USB–SATA bridge: they hide or mangle SMART
  and most block the ATA command `hdparm --make-bad-sector` issues (WRITE
  UNCORRECTABLE EXT), which is how every SMART-visible scenario is
  produced. A cheap PCIe AHCI card (ASMedia ASM1166 / JMicron JMB585) is
  an acceptable fallback if the board has too few ports.
- **Boot disk separate from test disks**, on NVMe, so that `/`,
  `/var/lib/kubelet` and `/var/lib/containerd` can never share a device with
  a test disk. The injection scripts refuse such a device anyway.
- **One test drive connected per block of scenarios** (section 3). The
  collector reads every disk `smartctl --scan` finds, so a second test
  drive left plugged in would appear in every fixture. Swap drives with the
  node powered off.
- No NVMe test drive: no scenario needs one (`hardware` is only ever
  `real-sata` or `scarred-sata`), and NVMe has no portable way to move SMART
  counters.

### Test drives

Every scenario's fault is produced by a script, except the old, stable
reallocated count that five scenarios need, which only a genuinely worn
drive has. Three drive roles:

| Role | Inventory id | What it must show | Used by |
|---|---|---|---|
| **Clean** | `clean` | Reallocated 0, pending 0, uncorrectable 0; supports WRITE UNCORRECTABLE (pending rises on `pending-sectors.sh start` and clears on `stop`) | 20 dm, filesystem, exhaustion and pending-sector scenarios |
| **Scarred** | `scarred` | Reallocated > 0 and **unchanged for ≥ 48 h**, pending 0, no read errors on a full surface read | 5 stable-defect scenarios |
| **Degrader** | `degrader` | Reallocated count actually rises when `degradation.sh` runs | 5 degradation scenarios |

The degrader is whichever drive passes the degradation test: try the
spare clean drive first, then the scarred candidates. A healthy drive often
satisfies the rewrite of a WRITE-UNCORRECTABLE sector in place without
reallocating (`degradation.sh` says whether it reallocates "is the drive's
decision"), so be ready for the clean drive to fail this test.

**Buying.** 3.5" or 2.5" SATA HDDs, 500 GB–2 TB (smaller is quicker to
surface-scan and mkfs). Prefer CMR to SMR (check the model against a
published SMR list): SMR adds latency spikes that would muddy the
`io-timeout`/probe scenarios. No SSDs: they usually reject WRITE
UNCORRECTABLE and remap invisibly.

| Buy | Qty | Why that many |
|---|---|---|
| Healthy SATA HDD (new, or used with zero counters) | 2 | one clean, one spare / first degrader candidate |
| Used SATA HDD with reallocated sectors | 5–6 | expect a third to half to qualify as scarred or degrader; the rest are too far gone (pending > 0, still growing, slow) or reject WRITE UNCORRECTABLE |

Look on eBay UK for used/"pulled" drives and "for parts / SMART warning"
listings; ask the seller for `smartctl -a` or a CrystalDiskInfo
screenshot, and prefer listings that state a reallocated count with zero
pending. Sellers rarely price defects in, so they cost the same as healthy
pulls.

**Screening on arrival** (on any Linux box, or `worker-02` before
Kubernetes; record every result in the drive's inventory `notes`):

1. Label the drive with its serial and a role candidate.
2. `smartctl -a /dev/sdX`: note reallocated (5), pending (197),
   uncorrectable (198), power-on hours, CRC errors (199). Reject pending > 0
   for the scarred role.
3. `smartctl -t long /dev/sdX`, then `smartctl -l selftest /dev/sdX`.
   Reject a failed self-test.
4. Read-only surface scan: `badblocks -sv /dev/sdX` (read-only by default).
   Reject a scarred candidate with read errors.
5. Repeat step 2 after 48 h of the drive powered and idle. A scarred drive's
   counters must not have moved.
6. On the rig, after it is built: run `pending-sectors.sh start`/`stop`
   against the drive (run book step 6) and check `smartAfterInjection`
   shows pending up and `smartAfter` shows it cleared. A drive where pending
   does not move cannot serve any `real-sata` scenario.

### Parts list

Rough estimates in GBP as of October 2026, used/refurbished unless noted.
Unverified: a web search found UK refurbished 1-litre i5 / 16 GB mini PCs
at about £220 with warranty (eBay is typically lower), EU listings for
micro-towers at the equivalent of £280–300, and used 1–2 TB SATA drives on
eBay UK at £7–£20; I could not confirm current sold prices. Check eBay UK
*sold* listings before buying.

| Item | Qty | Each | Total |
|---|---|---|---|
| Mini PC (Lenovo M720q / HP EliteDesk 800 G4 Mini / Dell OptiPlex 7060 Micro class), i5, 16 GB, 256 GB SSD | 2 | £100–220 | £200–440 |
| Micro-tower for `worker-02` (OptiPlex 7060 MT / EliteDesk 800 G4 TWR / ThinkCentre M920t class), i5, 16 GB, M.2 slot | 1 | £120–280 | £120–280 |
| NVMe SSD 256–512 GB for `worker-02` boot, if not included | 1 | £20–35 | £20–35 |
| Healthy SATA HDD 1 TB | 2 | £15–45 | £30–90 |
| Used SATA HDD with reallocated sectors | 6 | £5–20 | £30–120 |
| SATA data cables, crimped (not moulded) SATA power splitter | 1 set | £10–15 | £10–15 |
| 5-port gigabit switch, patch leads | 1 | £15–25 | £15–25 |
| Line-interactive UPS, 600–900 VA (recommended) | 1 | £70–120 | £70–120 |
| USB stick for the installer, drive labels | 1 | £5–10 | £5–10 |
| **Total** | | | **£500–1,135; about £750 typical** |

The UPS is optional but recommended. A power cut mid-capture loses the
collector's in-memory SMART history (which the stable-defect scenarios need
24 h of), can leave a dm table or bad-sector set active, and is the most
likely way to wreck a filesystem during a fault. Drop it and save £70–120
if the supply is reliable; plug all three nodes and the switch into it if
not.

## 3. Scenario coverage matrix

Drive: **C** clean, **S** scarred, **D** degrader. "dm" means the fault is a
device-mapper table swapped under `/dev/mapper/tropis-target` on that drive.
All scenarios run on `worker-02`; `TROPIS_DISK` is the drive's inventory id.

| # | Scenario | Expected | Drive | Fault produced by | Notes |
|---|---|---|---|---|---|
| 1 | pending-sectors-postgres | causal/host | C, `real-sata` | `pending-sectors.sh` (hdparm) | `target-blocks.sh` on the postgres table file (4.7 step 3) |
| 2 | pending-sectors-log-writer | causal/host | C, `real-sata` | `pending-sectors.sh` | `target-blocks.sh` on a `log-writer/segment-*` file; inject straight after, as the writer rewrites them |
| 3 | pending-sectors-batch-reader | causal/host | C, `real-sata` | `pending-sectors.sh` | `target-blocks.sh` on `batch/dataset` |
| 4 | pending-sectors-slow-probes | causal/host | C, `real-sata` | `pending-sectors.sh` | `target-blocks.sh` on the postgres table file; stalls depend on the drive's retry behaviour |
| 5 | degradation-postgres-gradual | causal/host | D, `real-sata` | `degradation.sh` STEP=4 INTERVAL=300 | reallocated must rise |
| 6 | degradation-minio | causal/host | D, `real-sata` | `degradation.sh` STEP=4 INTERVAL=300 | |
| 7 | degradation-fsync | causal/host | D, `real-sata` | `degradation.sh` STEP=8 INTERVAL=120 | |
| 8 | degradation-slow-probes | causal/host | D, `real-sata` | `degradation.sh` STEP=4 INTERVAL=300 | |
| 9 | read-errors-postgres | causal/host | C, dm | `read-errors.sh` (dm-dust) | `target-blocks.sh` on the postgres table file |
| 10 | read-errors-with-stable-defects | causal/host | **S**, `scarred-sata`, dm | `read-errors.sh` + natural stable defects | `target-blocks.sh` on a `log-writer/segment-*` file; inject straight after, as the writer rewrites them |
| 11 | write-errors-postgres | causal/host | C, dm | `write-errors.sh` (dm-flakey) | |
| 12 | write-errors-intermittent-uploads | causal/host | C, dm | `write-errors.sh` UP_SECS=25 DOWN_SECS=5 | |
| 13 | write-errors-readonly-remount | causal/host | C, dm | `write-errors.sh` | ext4 needs `errors=remount-ro` |
| 14 | io-timeout-postgres-probes | causal/host | C, dm | `io-timeouts.sh` (dm-delay) | known not raised |
| 15 | io-timeout-log-writer | causal/host | C, dm | `io-timeouts.sh` DELAY_MS=15000 | known not raised |
| 16 | fs-corruption-readonly | causal/host | C | `fs-corruption.sh` | VICTIM in `log-writer/`; mkfs after |
| 17 | fs-corruption-app-errors | causal/host | C | `fs-corruption.sh` | VICTIM=`batch/dataset`; mkfs after |
| 18 | read-errors-batch | causal/host | C, dm | `read-errors.sh` | `target-blocks.sh` on `batch/dataset` |
| 19 | exhaustion-log-spam | causal/k8s | C (idle) | `ephemeral-exhaustion.sh`, then the `log-spam` workload | container exceeds its ephemeral-storage limit and is evicted; see 4.7 |
| 20 | exhaustion-emptydir | causal/k8s | C (idle) | `ephemeral-exhaustion.sh`, then the `emptydir-filler` workload | emptyDir exceeds its `sizeLimit` and the pod is evicted; see 4.7 |
| 21 | stable-defects-config-crash | coincidental | **S**, `scarred-sata` | natural defects; no injection | collector up ≥ 24 h on S |
| 22 | stable-defects-oom | coincidental | **S**, `scarred-sata` | natural defects | `memory-hog-nodisk`: no storage on the disk |
| 23 | pending-sectors-unrelated-oom | coincidental | C, `real-sata` | `pending-sectors.sh` | `memory-hog-nodisk` (no volumes); default (mid-disk) LBAs |
| 24 | containerd-kill-stable-defects | coincidental | **S**, `scarred-sata` | `containerd-kill.sh` KILLS=5 INTERVAL=60 + natural defects | confirm is `<node>/containerd` |
| 25 | read-errors-unused-region-config-crash | coincidental | C, dm | `read-errors.sh`, default mid-disk blocks | check no workload file sits there |
| 26 | stable-defects-healthy-hostpath-oom | coincidental | **S**, `scarred-sata` | natural defects | `memory-hog`: hostPath on the disk, by design |
| 27 | pending-no-symptoms | insufficient | C, `real-sata` | `pending-sectors.sh` | `idle` workload |
| 28 | unreadable-smart-restarts | insufficient | C, `smart-withheld` | SMART withheld + `silent-kill.sh` | `batch-reader-silent`; collector as a non-root user, last before the pending-sector scenarios (4.7) |
| 29 | pending-silent-137 | insufficient | C, `real-sata` | `pending-sectors.sh` + `silent-kill.sh` | `batch-reader-silent`; default (mid-disk) LBAs, away from the dataset; kills: see 4.7 |
| 30 | degradation-early-no-symptoms | insufficient | D, `real-sata` | `degradation.sh` STEP=2 INTERVAL=600 | `idle` workload |

By drive: **C** 20 scenarios (7 real-SATA, 13 others including #28), **S** 5,
**D** 5. Order on the clean drive: dm and
filesystem scenarios first, then #28 (which restarts the collector; see
4.7), then pending-sector ones, because hdparm faults
can leave a permanent reallocation that would turn a "clean" drive into a
scarred one. Degradation is last on whichever drive is the degrader, since
it is meant to leave permanent marks.

## 4. Run book

### 4.1 OS

1. Firmware on every node: SATA mode AHCI, boot from the internal SSD, power
   restore "last state" (so a power blip brings the rig back).
2. Ubuntu Server 24.04 LTS, **stock GA `-generic` kernel** (no HWE or
   custom kernel; Talos is ruled out for the same reason, and because the
   injection scripts need a root shell on the node). Install only to the
   NVMe/boot SSD; leave the test drive unplugged during install.
3. On `worker-02`:

   ```sh
   sudo apt install smartmontools hdparm dmsetup e2fsprogs util-linux kmod make git jq
   sudo modprobe -a dm_dust dm_flakey dm_delay && dmsetup targets
   ```

   If `dm_dust` is missing, install `linux-modules-extra-$(uname -r)`.

### 4.2 Verify dm-dust before Kubernetes

On `worker-02`, before Kubernetes so Docker cannot collide with the cluster's
containerd: install Go (version from `go.mod`) and `docker.io`, clone the
repo, then

```sh
make inject-test REQUIRE_DUST=1
```

It works on loop devices in a container and touches no rig disk. It fails
unless dm-dust is what the scripts actually used. Then
`sudo apt purge docker.io containerd runc` before installing Kubernetes.

### 4.3 Kubernetes: kubespray

Kubespray is the simplest supported choice: the build brief names
"stock kubespray or Talos", Talos cannot run the injection scripts, and
kubespray installs a stock upstream cluster on Ubuntu with containerd as the
systemd unit `containerd` that `containerd-kill.sh` kills. Run it from the
control-plane node or WSL (Ansible does not run on Windows natively), with
its default versions, and record `kubernetesVersion` and
`containerRuntime` in the inventory. Plain `kubeadm` would also work; if you
use it, set `distribution: kubeadm`.

Then:

- **The baseline** (the incumbent; below): kube-prometheus-stack,
  smartctl_exporter and the k8sgpt CLI.
- **Tropis**, from the published chart, at one pinned release, with the
  matching `tropis` CLI from the same GitHub Release:

  ```sh
  helm install tropis oci://ghcr.io/i-am-webbo/charts/tropis --version <x.y.z> \
    -n tropis-system --create-namespace --set backend.provider=mock
  ```

  Capture uses only the collector DaemonSet; `mock` keeps the sweep from
  needing an API key or sending anything off the rig. Do not upgrade or
  restart the chart during a block: the collector's SMART history is held
  in memory, and the stable-defect scenarios need 24 h of it.

**The baseline** is what each fixture records the incumbent saw
(`baseline` in `fixture.json`: firing alert names from Prometheus's
`/api/v1/alerts`, and k8sgpt's output verbatim). Uplift over it is the
claim that matters, so it is a **strong** incumbent rather than the bare
"stock Prometheus" the project plan names: a team that runs bare-metal
SATA and cares about disks would add SMART monitoring, and beating a
baseline that cannot see disks at all would prove little. All versions
are exact, pinned on 2026-10-19 from each project's latest release:

| Component | Version | Configuration |
|---|---|---|
| kube-prometheus-stack (prometheus-community chart) | 92.10.1 | Default rules, unchanged. [`kube-prometheus-stack.yaml`](../hack/capture/baseline/kube-prometheus-stack.yaml) only places Prometheus, Alertmanager and Grafana on `worker-01` |
| prometheus-smartctl-exporter (prometheus-community chart) | 0.17.1, exporter v0.14.0 (its default; v0.15.0 is out but no chart ships it yet) | The chart's own PrometheusRule turned on unchanged, and its ServiceMonitor; [`smartctl-exporter.yaml`](../hack/capture/baseline/smartctl-exporter.yaml) |
| SATA SMART rules | [`smart-ata-rules.yaml`](../hack/capture/baseline/smart-ata-rules.yaml) | See below |
| k8sgpt CLI | v0.4.40 | `analyze` with its default (core) analyzers, no `--explain`, so no LLM |

Where the SMART alert rules come from: the exporter chart ships a
PrometheusRule (Apache-2.0, installed from the chart rather than copied
here) with six alerts: NVMe media errors, NVMe critical warning, NVMe
available spare, overall SMART status, interface speed and temperature.
The community set at awesome-prometheus-alerts (CC BY 4.0) covers the same
ground. Neither has a rule on the ATA counters the rig's SATA faults move,
so with them alone the SMART side of the incumbent could only fire if a
drive failed its own overall assessment. `smart-ata-rules.yaml` adds three,
written here rather than copied, after published practice: the two checks
`smartd` makes by default (`-a` includes `-C 197 -U 198`: warn while
`Current_Pending_Sector` or `Offline_Uncorrectable` is non-zero) and the
reallocated-sector growth alert Mirantis StackLight ships, over an hour
instead of ten minutes for the reason under *Alert durations*. They were
fixed before any capture; never change them to suit a result.

**Privileges.** The exporter is a privileged root container on every node
with `/dev` mounted, running `smartctl` every 120 s
(`collect_not_more_than_period`): it needs that to read SMART at all, as
Tropis's collector does. It needs no Kubernetes API access, so the chart's
RoleBinding (to a PodSecurityPolicy role that no longer exists) is off.
k8sgpt only reads; it runs with the capture machine's kubeconfig. Prometheus
needs nothing beyond the chart's defaults.

Install, from a checkout of the repository:

```sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 92.10.1 \
  -n monitoring --create-namespace -f hack/capture/baseline/kube-prometheus-stack.yaml
helm install smartctl-exporter prometheus-community/prometheus-smartctl-exporter --version 0.17.1 \
  -n monitoring -f hack/capture/baseline/smartctl-exporter.yaml
kubectl apply -f hack/capture/baseline/smart-ata-rules.yaml
```

and k8sgpt on `worker-02`, which runs the captures:

```sh
v=v0.4.40
curl -fsSLO https://github.com/k8sgpt-ai/k8sgpt/releases/download/$v/k8sgpt_Linux_x86_64.tar.gz
curl -fsSLO https://github.com/k8sgpt-ai/k8sgpt/releases/download/$v/checksums.txt
sha256sum --ignore-missing -c checksums.txt
tar -xzf k8sgpt_Linux_x86_64.tar.gz k8sgpt && sudo install k8sgpt /usr/local/bin/
k8sgpt version
```

**Quiet check.** With no scenario running and the cluster idle for 30
minutes, the only firing alerts must be `Watchdog` (always firing, by
design) and `InfoInhibitor`:

```sh
kubectl -n monitoring port-forward svc/prometheus-operated 9090 &
curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.state=="firing") | .labels.alertname' | sort -u
```

Anything else would sit in every fixture's baseline and is a setup fault:
fix the cause and record the fix with the run logs. A control-plane
component or kube-proxy whose metrics endpoint listens only on 127.0.0.1,
for instance, shows up as `TargetDown` or `Kube…Down`: set its bind
address in kubespray's inventory and re-run it. Never silence a default
rule to get there.

**The k8sgpt command.** `tropis-eval` holds only the scenario's pods, all
pinned to `worker-02`, so namespacing it there restricts it to the node
under test (its `Node` analyzer is cluster-scoped and reports any node; the
other two should be healthy). A config file of its own keeps any
`active_filters` set on the machine from narrowing the analyzers:

```sh
echo 'active_filters: []' > k8sgpt.yaml
k8sgpt --config k8sgpt.yaml analyze --namespace tropis-eval --no-cache --output text > k8sgpt.txt
```

`capture --k8sgpt-file k8sgpt.txt` stores it verbatim, header lines
included. In `npd-present` its `Node` analyzer also lists NPD's conditions;
that is the incumbent's view, and it is never model input.

**Alert durations.** Most default rules hold an alert pending before it
fires: `KubePodCrashLooping`, `KubePodNotReady`, the replica-mismatch
alerts and `KubeJobFailed` need 15 minutes, `NodeDiskIOSaturation` 30
minutes and `KubeContainerWaiting` an hour; the SMART rules need 1 minute
after the exporter's next read (up to 2 minutes) and Prometheus's next
scrape (1 minute). Read 2 minutes after injecting, as Tropis's own
capture could be, the baseline would show almost nothing, and the uplift
would be an artefact of timing. So the baseline is read, and the fixture
captured, **15 minutes after the symptom is confirmed** (4.7 step 4). That
gives the main Kubernetes alerts and every SMART alert their full
duration. The 30-minute and hour-long ones are not waited for: they are
not designed for an incident's first minutes, and holding a fault for an
hour per capture would double the run. The wait goes into each fixture's
`baseline.notes`, and the SMART growth rule's one-hour window is what keeps
a reallocation made at injection inside it. Holding the fault longer is
harmless to the fixture: capture checks the SMART change and the symptom
state at the moment it runs, and Tropis's event window is six hours.

**node-problem-detector** is installed only for the `npd-present` pass
(4.7, *Switching variant*), never in 4.3's initial setup. It is **stock
upstream NPD**: the project's own manifests (`deployment/` in
kubernetes/node-problem-detector) at release **v1.37.0**, pinned on
2026-10-19 (the latest release that day; upstream's manifests still name
the v0.8.19 image, so the image is set to v1.37.0's, by digest).
[`hack/capture/npd/kustomization.yaml`](../hack/capture/npd/kustomization.yaml)
pins both, and changes nothing else:

```sh
kubectl apply -k hack/capture/npd                     # install
kubectl -n kube-system rollout status daemonset node-problem-detector
kubectl -n kube-system logs daemonset/node-problem-detector | grep -i monitor   # all three started
kubectl delete -k hack/capture/npd                    # uninstall; then clear its conditions (4.7)
```

The inventory has no field for tool versions (unknown fields are errors),
so the NPD version is recorded here and in each run's log by the capture
driver (4.7), not in the inventory.

Why stock, and why without Tropis's SMART plugin
([hack/npd-plugin](../hack/npd-plugin/README.md)): stock NPD is what an
adopter's cluster has today, and the plugin is not upstream; the plugin runs
the same rules as Tropis's own pre-filter, which is already a trigger in
both variants, so enabling it would test nothing new; and NPD's conditions
and events never reach the model either way (AGENTS.md), so what the variant measures
is whether NPD's own conditions change which nodes get raised.

Monitors enabled (upstream's DaemonSet passes
`--config.system-log-monitor=/config/kernel-monitor.json,/config/readonly-monitor.json,/config/docker-monitor.json`;
no custom-plugin or system-stats monitor). What each can do in our
scenarios, from the v1.37.0 configs:

| Monitor | Reads | Conditions (start `False`) and events | Expected here |
|---|---|---|---|
| `kernel-monitor` | `/dev/kmsg` | `KernelDeadlock`, `ReadonlyFilesystem`; events `OOMKilling`, `TaskHung`, `UnregisterNetDevice`, `KernelOops`, `MemoryReadError` | `ReadonlyFilesystem=True` on #13 `write-errors-readonly-remount` and #16 `fs-corruption-readonly` (rule `Remounting filesystem read-only`, which ext4 prints under `errors=remount-ro`). A `TaskHung` event is possible on #14/#15 if a task blocks past `hung_task_timeout_secs` (120 s). `OOMKilling` is not expected: its pattern is the older two-line "Kill process … or sacrifice child" message, which the 6.8 kernel does not print. `KernelDeadlock` only on a hung *docker* task: never |
| `readonly-monitor` | `/dev/kmsg` | `ReadonlyFilesystem` (the same rule, with metrics) | as above |
| `docker-monitor` | journald, source `dockerd` | events `CorruptDockerImage` only | never: kubespray runs containerd and nothing logs as `dockerd` |

**containerd.** kubespray's runtime is containerd, and stock NPD watches
docker. Upstream does ship containerd configs
(`health-checker-containerd.json`, and `FrequentContainerdRestart` in
`systemd-monitor-counter.json`) but its DaemonSet enables none of them, so
#24 `containerd-kill-stable-defects` will carry no NPD condition about
containerd in its `npd-present` fixture. That is the adopter's default,
and it is what this variant records. (The dev corpus's synthetic hint for
#24, `npd: containerd-restart`, assumes otherwise; it affects only
`eval/testdata`.) The conditions NPD sets on every node from start-up,
`KernelDeadlock` and `ReadonlyFilesystem` at `False`, are what tells
`capture` the variant is present.

### 4.4 Inventory

Copy [`hack/inventory.example.yaml`](../hack/inventory.example.yaml) to
`rig.yaml` (keep it out of git if it holds real addresses). For `worker-02`
list the boot disk (`destructible: false`) and the test disk currently
installed, with `byId` (`ls -l /dev/disk/by-id/ata-*`), `serial` (as
`smartctl -i` reports it), `transport: sata`,
`destructible: true` and `mountpoint: /mnt/disks/sacrificial`. Use the role
as the id (`clean`, `scarred`, `degrader`) and edit the entry when you swap
drives, so each fixture records the right model and serial. Check it:

```sh
tropis inventory validate rig.yaml
tropis inventory target --inventory rig.yaml --node worker-02 --disk clean
```

### 4.5 Safety rules

- **The injection scripts destroy data.** Run them only on `worker-02`, only
  against a drive marked `destructible: true`, only as part of this run.
  Never on a development machine.
- Physically label every drive with its serial and role; the boot SSD gets a
  "BOOT — never" label.
- Never mark the boot disk destructible, never mount a test disk at a system
  path, and never point kubelet or containerd storage at a test disk. The
  scripts refuse all three; do not work around a refusal.
- The two exhaustion workloads write to the boot disk, through the kubelet's
  ephemeral storage, at most 512 MiB each, rate-limited. Never raise their
  caps or remove their limits, and never fill the kubelet's filesystem to
  make DiskPressure happen.
- `TROPIS_INJECT_CONFIRM` is set per session to exactly `worker-02/<disk>`.
  Unset it when you stop for the day.
- Before swapping drives: every fault `stop`ped (`<script> status`),
  `prepare.sh stop`, power off.

### 4.6 Per-drive setup and acceptance

On `worker-02`, as root, with `tropis` and `tropis-collector` on `PATH`:

```sh
export TROPIS_INVENTORY=rig.yaml TROPIS_NODE=worker-02 TROPIS_DISK=clean
export TROPIS_INJECT_CONFIRM=worker-02/clean
hack/inject/prepare.sh start
mkfs.ext4 -F /dev/mapper/tropis-target
mkdir -p /mnt/disks/sacrificial
mount -o errors=remount-ro /dev/mapper/tropis-target /mnt/disks/sacrificial
```

Acceptance for a `real-sata` drive (before any capture):
`hack/inject/pending-sectors.sh start` then `stop`, and check the records'
`smartBefore`, `smartAfterInjection`, `smartAfter`. For the degrader:
`STEP=4 INTERVAL=60 hack/inject/degradation.sh start`, wait 10 minutes,
`stop`, and check that `reallocated` rose. Then mkfs again. After an
acceptance test, restart the collector so its history does not carry the
test: `kubectl -n tropis-system rollout restart daemonset` on the collector.

### 4.7 One capture

Do every scenario on the current drive with NPD absent, then install NPD
and do them all again with it present.

**Use the capture driver.** On `worker-02`, as root, from a checkout, with
the drive set up as in 4.6:

```sh
export TROPIS_INVENTORY=rig.yaml TROPIS_NODE=worker-02 TROPIS_DISK=clean
export TROPIS_INJECT_CONFIRM=worker-02/clean
hack/capture/run-scenario.sh --dry-run <scenario> npd-absent   # read the plan first
hack/capture/run-scenario.sh <scenario> npd-absent
```

[`hack/capture/run-scenario.sh`](../hack/capture/README.md) does steps 1–7
below for one scenario and variant, reading the scenario from `tropis
scenario show` (so from `scenarios.yaml` as built into the `tropis`
binary; its `inject.target` and `symptom` fields carry what the coverage
matrix's notes say about aiming the fault and the silent kills). It checks
what can be checked: the NPD variant against the node, no fault left
active, the pass-through onto the inventory's target before mkfs, the
collector's fresh pre-fault reading (or its 24 h of history for
`scarred-sata`), every pod started, every silent kill delivered, an
`expectSmart` counter above the start record's `smartBefore`, an eviction
with `DiskPressure` `False` for exhaustion, and no leftover alert. What it
cannot judge, that the scenario's symptom is really there, it asks: it
shows the pods and events and the operator must type `yes`, once before
and once after the 15-minute baseline wait. It stops the fault (and the
silent kills, and the `smart-withheld` patch) on any exit, writes every
record to a run directory outside `eval/fixtures`, never passes `--force`
unless `RETAKE=1`, and has the operator type the containerd and
silent-kill confirmations. It does not switch the NPD variant, swap drives
or soak a scarred drive; those stay manual (below).

The manual steps, for reference and for when the driver stops:

1. **Reset.** `kubectl delete namespace tropis-eval --wait`; unmount, mkfs
   and remount as in 4.6. For a SMART-visible scenario, also restart the
   collector so its oldest snapshot is a pre-fault reading, and wait 2
   minutes (the collector rate-limits reads to one a minute). This is
   required: capture compares the drive against that reading and refuses
   without it. Before the next workload, wait until no firing alert
   carries `namespace="tropis-eval"` (the last scenario's
   `KubePodCrashLooping` looks back five minutes), or it lands in this
   scenario's baseline:
   `curl -s localhost:9090/api/v1/alerts | jq '[.data.alerts[] | select(.state=="firing" and .labels.namespace=="tropis-eval")] | length'`
   must print 0.
2. **Workload.** `export TROPIS_NODE=worker-02 TROPIS_MOUNT=/mnt/disks/sacrificial`
   then `envsubst < eval/scenarios/workloads/<workload>.yaml | kubectl apply -f -`
   and wait until it is in steady state.
3. **Inject** with the scenario's `params` as environment variables:
   `STEP=4 INTERVAL=300 hack/inject/degradation.sh start > fault.json`.
   Skip for scenarios with no `inject`.

   **Targeting a workload's data.** Where the matrix says to target a
   file, compute the sectors under it with `hack/inject/target-blocks.sh`
   before injecting (it refuses while a fault is active), and pass them
   explicitly:

   ```sh
   eval "$(hack/inject/target-blocks.sh /mnt/disks/sacrificial/batch/dataset)"
   SECTORS="$SECTORS" hack/inject/pending-sectors.sh start > fault.json    # or
   BAD_BLOCKS="$BAD_BLOCKS" hack/inject/read-errors.sh start > fault.json
   ```

   It prints four sectors (`COUNT`, at most 64) spread through the file,
   one per filesystem block, as physical LBAs (`SECTORS`, for hdparm) and
   as 512-byte blocks of `/dev/mapper/tropis-target` (`BAD_BLOCKS`, for
   dm-dust); with the pass-through at offset 0 on a whole disk they are the
   same numbers. It reads the filesystem block size and the table's offset
   rather than assuming them, and refuses a file that is not on the
   tropis-target filesystem. The variables are not exported, so a later
   scenario that wants the mid-disk default still gets it. For postgres,
   the file is its table's: `kubectl -n tropis-eval exec postgres-0 -c
   postgres -- psql -U postgres -Atc "select pg_relation_filepath('t')"`
   gives a path under `/mnt/disks/sacrificial/postgres/pgdata/`.

   **Exhaustion scenarios swap steps 2 and 3**, because the workload is the
   fault: `hack/inject/ephemeral-exhaustion.sh start > fault.json` first,
   then apply `log-spam` or `emptydir-filler`. The script writes nothing; it
   refuses unless `/var/lib/kubelet`, `/var/lib/containerd` and
   `/var/log/pods` are off the test disk, containerd shares the kubelet's
   filesystem (kubespray's default; with a separate image filesystem the
   kubelet does not count container writable layers toward their limits),
   and that filesystem keeps 10 GiB and 20% free beyond the workloads'
   512 MiB write cap. Eviction comes within about 75 s of applying the
   workload. The clean test drive stays installed, idle and healthy, so the
   fixture records a healthy disk. Check that the node's `DiskPressure` is
   still `False` when you capture: these scenarios are evictions under no
   node pressure.

   **Silent-137 scenarios** (#28 `unreadable-smart-restarts`, #29
   `pending-silent-137`) add the symptom by hand after this step, once
   `batch-reader-silent` has been running for a minute (it writes its
   dataset first) and, for #29, the fault is in place:

   ```sh
   TROPIS_INJECT_CONFIRM=worker-02/silent-kill APP=batch-reader KILLS=3 INTERVAL=60 \
     hack/symptoms/silent-kill.sh start >> run-log.jsonl
   ```

   It SIGKILLs the reader's main process from the host, three times a
   minute apart, so the pod restarts with last state `Error`, exit code
   137, and no `OOMKilled` reason, no `Killing` event and no log line (the
   workload prints nothing). The kubelet's ordinary restart events
   (`Pulled`, `Created`, `Started`, `BackOff`) are unavoidable and explain
   nothing. Its record is a symptom record for the run log: never put it in
   `fault.json` or pass it to `--injection`. For #29 leave `SECTORS` at its
   mid-disk default, away from the dataset: a reader stuck in an
   uninterruptible read does not die on SIGKILL until the read returns.
   Stop it with `hack/symptoms/silent-kill.sh stop >> run-log.jsonl` after
   capturing.
4. **Wait for the symptom** the scenario describes (crash loop, probe
   failures, read-only remount, OOM kill, a pod `Evicted` for local
   storage, `silent-kill.sh status` reporting every kill delivered). For
   read-path faults, drop the page cache (`sync; echo 3 > /proc/sys/vm/drop_caches`) so reads reach the
   disk. Wait at least 2 minutes after injecting. For a `real-sata`
   scenario, also wait until the counter in its `expectSmart` has risen
   (`smartctl -A` on the drive: pending, attribute 197, for
   `pending-sectors`; reallocated, attribute 5, for `degradation`, which can
   take several intervals). `degradation.sh start` itself returns only after
   the worker's first step.

   Once the symptom is there, **wait 15 minutes more** before step 5, with
   the fault still active, so the incumbent's alerts have had their `for:`
   durations (4.3, *Alert durations*). Then check the symptom and, for a
   `real-sata` scenario, the raised counter again: a symptom that has gone
   is a setup failure, not a capture.
5. **Baseline.** Prometheus's alerts are read by `capture` itself
   (`--prometheus`); k8sgpt's output is saved first:

   ```sh
   kubectl -n monitoring port-forward svc/prometheus-operated 9090 &
   echo 'active_filters: []' > k8sgpt.yaml
   k8sgpt --config k8sgpt.yaml analyze --namespace tropis-eval --no-cache --output text > k8sgpt.txt
   ```
6. **Capture, while the fault is active:**

   ```sh
   tropis capture --scenario degradation-minio --variant npd-absent \
     --node worker-02 --disk degrader --inventory rig.yaml \
     --injection fault.json --prometheus http://localhost:9090 \
     --k8sgpt-file k8sgpt.txt \
     --baseline-notes "kube-prometheus-stack 92.10.1 default rules; prometheus-smartctl-exporter 0.17.1 rules; hack/capture/baseline/smart-ata-rules.yaml; k8sgpt v0.4.40 analyze, core analyzers, no --explain; read 15 min after the symptom"
   ```

   Capture writes into `--corpus` (default `eval/fixtures`, the directory
   `tropis eval --corpus` reads; `--out` is a deprecated alias). Omit
   `--injection` for a scenario with no `inject`. A refusal
   ("nothing was written") means the fixture would be untrue: fix the setup,
   don't force it. For a `real-sata` scenario capture finds the drive by
   the serial in `fault.json` and refuses unless an `expectSmart` counter is
   higher than in the collector's oldest reading; the error gives the
   counters before and after. If the counter is still due to move (a
   degradation interval has not passed), wait and capture again; if the
   drive does not react, the drive cannot serve the scenario.
7. **Stop** the fault: `hack/inject/<script> stop >> fault.json`. Keep the
   records with the run log (not in `eval/fixtures/`).

**Switching variant.** To `npd-present`: install NPD as in 4.3 and wait
until the node carries its conditions; `capture` refuses `npd-present`
otherwise:

```sh
kubectl apply -k hack/capture/npd
kubectl -n kube-system rollout status daemonset node-problem-detector
kubectl get node worker-02 -o jsonpath='{.status.conditions[*].type}'   # includes KernelDeadlock ReadonlyFilesystem
```

Back to `npd-absent` needs NPD uninstalled *and* its conditions removed
from the node status, or capture refuses (it counts every condition the
kubelet does not own). NPD does not remove them when it goes; the kubelet
only ever writes its own five, so replacing the list with those five
removes NPD's for good:

```sh
kubectl delete -k hack/capture/npd
kubectl -n kube-system wait --for=delete pod -l app=node-problem-detector --timeout=2m
kubectl get node worker-02 -o json |
  jq '{status: {conditions: [.status.conditions[] |
      select(.type | IN("Ready","MemoryPressure","DiskPressure","PIDPressure","NetworkUnavailable"))]}}' \
  > kubelet-conditions.json
kubectl patch node worker-02 --subresource=status --type=merge --patch-file kubelet-conditions.json
kubectl get node worker-02 -o jsonpath='{.status.conditions[*].type}'   # only the kubelet's five
```

(A JSON merge patch replaces the whole list. The five are the kubelet's
conditions as `pkg/k8s` defines them.)

**Between `npd-present` scenarios.** `ReadonlyFilesystem` is a permanent
condition: once #13 or #16 sets it `True`, NPD leaves it `True` until it
restarts, so the next scenario's fixture would carry a stale trigger. Before
the next scenario, `kubectl -n kube-system rollout restart daemonset
node-problem-detector` and wait until every NPD condition on the node is
`False`. NPD re-reads five minutes of `/dev/kmsg` on start, so this can take
up to five minutes after the remount. The capture driver does this at
every `npd-present` reset.

**Stable-defect block (S).** Install the scarred drive, set up as 4.6,
then leave the collector running untouched for ≥ 24 h before the first
capture, so its oldest snapshot is a day old with the same counts. These
scenarios (`hardware: [scarred-sata]`) must be captured with
`--disk scarred`: capture finds the drive by that inventory entry's
`serial` (required here; never by `device`, which can move) in both the
capture and the collector's oldest reading, and
refuses unless reallocated is above zero and unchanged and pending is 0 in
both readings. A refusal here means the drive is not (or is no longer) scarred;
there is no override.

**Withholding SMART (#28 `unreadable-smart-restarts`).** The collector
must be running but unable to read SMART. No chart value does that:
`securityMode: devicePlugin` without a device plugin leaves the pod
unschedulable, and an unprivileged container sees no disks at all, so
`smartctl --scan` finds nothing and the fixture would show an empty host
rather than an unreadable one. Instead keep the container privileged (so
the disks are still found) and run it as an unprivileged user, so every
`smartctl` open fails with "Permission denied", the same failure the dev
corpus's `unreadable` archetype carries:

```sh
kubectl -n tropis-system patch daemonset tropis-collector --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/securityContext/runAsUser","value":65534}]'
kubectl -n tropis-system rollout status daemonset tropis-collector
```

Wait 2 minutes, then reset, apply `batch-reader-silent` and run
`silent-kill.sh` as for #29 (there is no `inject`), and capture without
`--injection` (with `--disk clean`, as usual). The scenario declares
`hardware: [smart-withheld]`, and capture refuses unless the collector
tried at least one device and every one read as permission denied: a
device it could read, or one unreadable for another reason (a timeout is
evidence about the disk), would make the label untrue. If it refuses with
"no device at all", `smartctl --scan` found nothing as that user; name
the devices with `collector.scan` before patching. Revert straight after
capturing, and check the collector is back to `runAsUser: 0`:

```sh
kubectl -n tropis-system rollout undo daemonset tropis-collector
kubectl -n tropis-system rollout status daemonset tropis-collector
```

Both the patch and the undo restart the collector, which loses its
in-memory SMART history. Nothing in #28 needs that history, but a
SMART-visible capture does, so do #28 last among the clean drive's
non-SMART-visible scenarios, immediately before the pending-sector ones:
each of those restarts the collector at its reset anyway (4.7 step 1) and
needs nothing older. Never do it in the stable-defect block, whose 24 h
of history it would wipe. The block runs once per NPD variant, so #28
takes this place in both passes. The capture driver makes the patch after
its reset and undoes it on exit, and refuses to start if the collector
already runs as 65534 (an earlier undo was missed).
### 4.8 Check, commit, evaluate

1. Check each fixture: `label.json`'s `injection.params` show the SMART
   change you expected (`smartBefore` → `smartAfterInjection` for
   `real-sata`, degradation included; capture has already checked the
   fixture's own readings); `environment` names the right disk; there are 60
   directories.
2. Commit fixtures in batches, one commit per drive block, e.g.
   `test(eval): capture the clean-drive scenarios`, signed off. Do not
   edit any fixture or label by hand.
3. Only after all 60 are committed:

   ```sh
   tropis eval --corpus eval/fixtures --publishable --inventory rig.yaml
   ```

   `--publishable` refuses a corpus containing anything synthetic. The run
   writes `eval/results/<timestamp>/`; publish it deliberately.

## 5. Time and risks

### Schedule (one person, evenings and weekends)

| Phase | Effort | Elapsed |
|---|---|---|
| Buy parts; drives arrive from several sellers | 2–3 h | 1–2 weeks |
| Build, firmware, OS, `make inject-test REQUIRE_DUST=1`, kubespray, baseline and quiet check, Tropis | 1–2 days | |
| Screen drives (long self-test and surface scan ≈ 2–4 h per TB each, then 48 h soak) | 3–4 h hands-on | 3–4 days, overlaps the build |
| Clean-drive block: 20 scenarios × 2 variants, ≈ 45–60 min each (15 of them the baseline wait) | 30–40 h | 1–2 weeks |
| Scarred block: 24 h soak, then 5 × 2 | 8–10 h | 3 days |
| Degrader block: 5 × 2, ≈ 1.25–1.75 h each (gradual faults) | 12–18 h | 1 week |
| Retakes, checks, commit, eval | 4–8 h | 2–3 days |
| **Total** | **≈ 65–90 h** | **≈ 5–7 weeks** |

### Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Drive never reallocates under `degradation.sh` | 5 `real-sata` degradation scenarios (10 fixtures) cannot be captured truthfully | Buy 5–6 candidates; acceptance-test each; capture refuses a degradation fixture unless `reallocated` rose on the drive |
| Drive rejects WRITE UNCORRECTABLE or pending does not move | No `real-sata` pending scenarios on that drive | Acceptance test (4.6) before relying on a drive; keep a spare clean drive |
| Drive degrades too fast (scarred drive starts growing pending/realloc) | Stable-defect fixtures become causal-looking; drive may die mid-block | Screen with a 48 h soak; capture the S block promptly; check counters before each capture; have a second scarred candidate |
| Natural defects are unrepeatable | A scarred drive that changes cannot be "reset", and a retake will show different SMART | Capture the S block once, both variants back to back; keep the drive and its screening record; accept that a lost scarred drive means re-screening a new one |
| Symptoms don't appear (bad sectors not under the workload, page cache hides reads) | Fixture records a fault with no symptom, which is a different scenario | Target the workload's files with `target-blocks.sh`; drop caches; check the symptom before capturing |
| Exhaustion workload not evicted (limit enforcement off, or a dedicated image filesystem) | 4 positives cannot be captured truthfully | `ephemeral-exhaustion.sh` refuses a dedicated image filesystem; confirm the pod is `Evicted` for local storage before capturing, and treat no eviction as a setup failure |
| Power cut or reboot mid-block | Collector history lost; dm state lost; fs damage | UPS; after any reboot, restart the block's soak and reset |

## 6. Gaps for follow-up

1. **Resolved: exhaustion could not produce DiskPressure on the rig.** The
   scenarios now use per-pod limits instead: `log-spam` overruns its
   container's `ephemeral-storage` limit and `emptydir-filler` its emptyDir
   `sizeLimit`, and the kubelet evicts each with no node pressure. That is
   raised by `k8s.storage_eviction` (which now also matches the kubelet's
   container-limit message). Writes are capped at 512 MiB on the boot disk,
   and `ephemeral-exhaustion.sh` checks the node first. A dedicated
   sacrificial kubelet disk was rejected: it would add a disk to every
   fixture's SMART data and needs the kubelet reinstalled onto it. The
   expected answer stays `causal`/`kubernetes`; see the comment above the
   scenarios in `scenarios.yaml`.
2. ~~**Capture does not check that SMART moved.**~~ *Resolved.* Each
   `real-sata` scenario declares `expectSmart` (`pending_sectors` for
   `pending-sectors`, `reallocated_sectors` for `degradation`), and capture
   refuses the fixture unless one of those counters is higher in its own
   reading than in the collector's earlier one (`HostCapture.Previous`), on
   the drive whose serial the injection record names (snapshots now end in
   `serial=`), wherever its device path moved. `degradation.sh start` now
   waits for the first step and records `smartAfterInjection`.
3. ~~**Stable defects are not verified.**~~ *Resolved.* The five
   `realloc-stable` scenarios declare `hardware: [scarred-sata]`, and
   capture refuses them unless the drive named by `--disk` (its inventory
   `device`, then followed by serial) shows reallocated sectors above zero
   and unchanged since the collector's earlier reading, with pending 0 in
   both (non-zero pending means the drive is actively failing, and the
   expected answers assume it is not). The age of that reading is not checked; the 24 h soak in 4.7 is
   still the operator's job.
4. ~~**No helper to target a workload's blocks.**~~ *Resolved.*
   `hack/inject/target-blocks.sh <file>` prints `SECTORS` and `BAD_BLOCKS`
   for four blocks spread through the file (4.7 step 3), reading the
   filesystem block size from `filefrag` and the pass-through's offset
   from `dmsetup`, and refusing a file off the tropis-target filesystem, a
   table with a fault active, a partition and non-512-byte sectors.
   `make inject-test` injects at the blocks it names and checks that the
   file then fails to read while another file still reads.
5. ~~**`silent-137` has no injection.**~~ *Resolved.* Both scenarios now
   run `batch-reader-silent` (the batch reader with no output, which
   neither prints nor exits on a failed read), and
   `hack/symptoms/silent-kill.sh` SIGKILLs its container from the host
   through `crictl`, `KILLS` times, refusing anything that is not a
   `tropis.io/eval=true` pod in `tropis-eval` (4.7). It is a symptom
   helper, kept out of `hack/inject` because it is not the scenario's
   fault and must never reach a label; its record goes to the run log.
   The kubelet's ordinary restart events cannot be avoided and are not a
   cause.
6. ~~**Withholding SMART is undocumented.**~~ *Resolved.* No chart value
   leaves the collector running but unable to read SMART (`devicePlugin`
   without a plugin is unschedulable; unprivileged, it sees no disks). 4.7
   now patches the DaemonSet to run the collector as `runAsUser: 65534`,
   still privileged, so every device reads as permission denied, and
   reverts with `rollout undo`; it runs last before the pending-sector
   scenarios because both steps restart the collector. The scenario
   declares `hardware: [smart-withheld]`, and capture refuses it unless
   every device the collector tried was denied permission and none was
   read.
7. ~~**`memory-hog` contradicts one scenario.**~~ *Resolved.*
   `pending-sectors-unrelated-oom` and `stable-defects-oom` now run
   `memory-hog-nodisk`, the same OOM-killed pod with no volumes, so nothing
   it does touches the disk. `stable-defects-healthy-hostpath-oom` keeps
   `memory-hog`, whose hostPath on the disk is that scenario's point; with
   `stable-defects-oom` on the no-disk variant, the two differ in exactly
   that. The dev corpus follows the manifests, and a test checks that each
   synthetic pod has a hostPath exactly when its workload does.
8. ~~**NPD install is unspecified.**~~ *Resolved.* `npd-present` runs
   stock upstream NPD v1.37.0 from its own manifests, pinned by commit and
   image digest in `hack/capture/npd/kustomization.yaml`, with its default
   monitors (`kernel-monitor`, `readonly-monitor`, `docker-monitor`) and
   without Tropis's SMART plugin, which is not upstream and would only
   repeat the pre-filter's rules (4.3). 4.3 lists which scenarios can
   raise which condition (`ReadonlyFilesystem` on #13 and #16; nothing on
   containerd, which stock NPD does not watch), and 4.7 gives install,
   uninstall, clearing NPD's conditions from the node status, and
   restarting NPD between `npd-present` scenarios to clear a permanent
   condition. The inventory has no field for tool versions, so the
   version is recorded in the run book.
9. ~~**Baseline configuration is unspecified.**~~ *Resolved.* The
   incumbent is a strong one (4.3): kube-prometheus-stack 92.10.1 with its
   default rules, smartctl_exporter (chart 0.17.1) with the chart's own
   SMART rules plus three SATA rules after `smartd`'s defaults and
   StackLight's growth alert (`hack/capture/baseline/smart-ata-rules.yaml`,
   since no published rule set covers the ATA counters), and k8sgpt
   v0.4.40 `analyze --namespace tropis-eval` with its core analyzers and no
   `--explain`. Because the default Kubernetes alerts wait 15 minutes
   before firing, the baseline and the fixture are taken 15 minutes after
   the symptom is confirmed (4.7 step 4), and that is recorded in
   `baseline.notes`; alerts with 30-minute or hour-long durations are not
   waited for. A quiet check before the first capture keeps standing
   alerts out of every baseline.
10. ~~**No reset tooling.**~~ *Resolved.* `hack/capture/run-scenario.sh`
    drives one scenario and variant through 4.7: reset (namespace, mkfs
    after checking the pass-through, collector restart and fresh reading),
    workload, aimed injection, symptom helper, checks, the baseline wait,
    baseline, capture and stop. It reads each scenario through a new
    read-only `tropis scenario show`, which prints it as shell
    assignments, rather than parsing YAML in shell; `scenarios.yaml` gained
    `inject.target` and `symptom` so the aiming and silent kills the matrix
    describes are scenario data too. It automates the checks it can make
    and asks the operator to confirm the symptom; it never forces a
    capture. `--dry-run` prints the plan, and `make capture-test` (in `make
    check`) dry-runs it over every scenario in both variants, so a scenario
    it cannot drive fails the build.
11. ~~**NPD's events reach the model in `npd-present`.**~~ *Resolved*
    at prompt v5. An event about the node is evidence only when a
    Kubernetes component reported it (`kubelet`, `node-controller`,
    `cidrAllocator`, `kube-proxy`, by `reportingComponent` or
    `source.component`; `triggers.IsEvidence`), an allowlist like the
    kubelet's node conditions, since NPD reports under each monitor's
    configurable `source` and no list of its names can be complete. The
    collector moves the rest, in practice NPD's (`TaskHung`,
    `FilesystemIsReadOnly`), into a new `kubernetes.npdEvents`, which
    nothing passes to the model, and `reason.BuildInput` and the
    Kubernetes-side rules apply the same filter to `events`, so a fixture
    that still holds them there cannot leak them. Pod events are
    unchanged: NPD reports only on the Node. Tropis's own opt-in Node
    Events (reporting controller `tropis.io/sweep`) leaked the same way on
    the next sweep, carrying its previous verdict, and are now dropped at
    collection and filtered in `BuildInput`. No rule raises a node on
    `npdEvents` yet, so `npd-present` still differs from `npd-absent` in
    NPD's conditions only.
