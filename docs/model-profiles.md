# Model profiles

Tropis needs a reasoning backend. Which one fits depends on your hardware
and on whether cluster data may leave the cluster. Each profile below is a
values file in
[deploy/helm/tropis/examples/](../deploy/helm/tropis/examples/) that sets
only what differs from the chart's defaults. Install one with `-f`:

```sh
helm install tropis oci://ghcr.io/i-am-webbo/charts/tropis -n tropis-system \
  --create-namespace -f local-gpu-8gb.yaml
```

Change `baseURL`, or the Secret name for the claude profiles, to match your
cluster. Every setting is described with `backend` in
[values.yaml](../deploy/helm/tropis/values.yaml).

| Profile | Hardware | What leaves the cluster | Time per analysed node | Dev-corpus behaviour (30 cases) | Caveats |
|---|---|---|---|---|---|
| [claude](../deploy/helm/tropis/examples/claude.yaml) | None; an Anthropic API key in a Secret | The redacted evidence of each node the pre-filter raises, sent to Anthropic ([SECURITY.md](../SECURITY.md#what-leaves-the-cluster)) | Not yet measured | Not yet measured | The chart's default |
| [claude-sweep-escalate](../deploy/helm/tropis/examples/claude-sweep-escalate.yaml) | As claude | As claude, sent once or twice per node | Not yet measured | Not yet measured | Cheaper and less accurate: a sweep that is confidently wrong is never escalated |
| [local-gpu-8gb](../deploy/helm/tropis/examples/local-gpu-8gb.yaml) | A GPU with about 8 GB, running Ollama with `qwen3.5:9b` (6.6 GB) | Nothing | About 3 min (RTX 3070) | 18/20 detected end to end; 0/6 false causal claims; 1 error; `insufficient_evidence` correct 2/4 | Called two "cannot tell" cases coincidental |

"Detected end to end" means the pre-filter raised the fault and the verdict
named the right relationship and layer. "False causal claims" counts the
negative controls (the coincidental cases) called causal. An error is an
analysis that produced no verdict, which Tropis reports as an error rather
than guessing. The terms are defined in
[eval/README.md](../eval/README.md#what-is-measured). The pre-filter raised
18 of the 20 faults, so 18/20 is the most any model could score.

## What the numbers are, and are not

**The dev corpus is synthetic.** These numbers come from fixtures generated
from `eval/scenarios`, not captured from real hardware. They compare
backends with each other on the same cases and must not be quoted as
Tropis's accuracy. The published number will come from the capture run on
real hardware ([docs/capture-rig.md](capture-rig.md)). Until then there is
none.

Read them with three more caveats:

- **Thirty cases are few.** A model run twice on the same input does not
  always answer the same: one case flipped between two runs with nothing
  relevant changed. Treat a difference of one or two cases as noise.
- **The corpus cannot catch over-claiming.** It has no negative control in
  which a workload shows disk-like symptoms (a read-only filesystem, I/O
  errors) that the disk did not cause. A model that says `causal` too
  readily on such symptoms would not be penalised here.
- **Nine of the thirty cases informed prompt v4.** Prompt v4 was written
  after looking at nine cases that v3 got wrong or nearly wrong. On the 21
  cases not looked at, qwen3.5:9b improved from 14 to 18 correct between v3
  and v4 at the same settings, so the change was not only fitted to the nine.

## Other models that fit an 8 GB GPU

Measured the same way, at the chart's default `contextTokens` (16384):

| Model | Download | Detected end to end | False causal claims | Errors | `insufficient_evidence` correct | Whole corpus |
|---|---|---|---|---|---|---|
| `qwen3.5:9b` at 32768 (the profile) | 6.6 GB | 18/20 | 0/6 | 1 | 2/4 | 1h39m |
| `qwen3.5:9b` | 6.6 GB | 16/20 | 0/6 | 2 | 2/4 | 1h01m |
| `gemma4:12b-it-qat` | 7.2 GB | 16/20 | 0/6 | 2 | 2/4 | 1h06m |
| `granite4.2:8b` | 5.3 GB | 13/20 | 0/6 | 0 | 4/4 | 1h26m |

- **gemma4:12b-it-qat** matches qwen3.5:9b at the same window, and is a
  reasonable alternative.
- **granite4.2:8b** is the most cautious. It never failed to give a
  verdict and was the only model to answer every "cannot tell" case
  correctly, but it said `insufficient_evidence` on three real faults and
  missed more of them.

The cases any of them got wrong:

| Case | Truth | qwen3.5:9b (32768) | qwen3.5:9b | gemma4:12b | granite4.2:8b |
|---|---|---|---|---|---|
| exhaustion-emptydir | causal, kubernetes | ✓ | coincidental ✗ | ✓ | coincidental ✗ |
| exhaustion-log-spam | causal, kubernetes | ✓ | ✓ | coincidental ✗ | coincidental ✗ |
| fs-corruption-app-errors | causal, host | ✓ | ✓ | ✓ | insufficient_evidence ✗ |
| fs-corruption-readonly | causal, host | ✓ | error ✗ | ✓ | ✓ |
| io-timeout-log-writer | causal, host | ✓ | ✓ | ✓ | coincidental ✗ |
| io-timeout-postgres-probes | causal, host | error ✗ | ✓ | ✓ | ✓ |
| pending-no-symptoms | insufficient_evidence | ✓ | ✓ | error ✗ | ✓ |
| pending-silent-137 | insufficient_evidence | coincidental ✗ | coincidental ✗ | coincidental ✗ | ✓ |
| read-errors-with-stable-defects | causal, host | ✓ | ✓ | error ✗ | ✓ |
| unreadable-smart-restarts | insufficient_evidence | coincidental ✗ | error ✗ | ✓ | ✓ |
| write-errors-postgres | causal, host | ✓ | ✓ | ✓ | insufficient_evidence ✗ |
| write-errors-readonly-remount | causal, host | ✓ | ✓ | ✓ | insufficient_evidence ✗ |

Every error was the model's hidden reasoning running on until it filled the
context window or hit the request timeout. A larger window gave
qwen3.5:9b room to finish more often, which is why the profile sets 32768.
It costs time: on the test machine, more of the model had to run on the CPU
to make room.

Not measured: newer and larger models (Qwen 3.6 and later, `gpt-oss:20b`,
26–35B mixture-of-experts models) are bigger than an 8 GB card can hold
without running mostly on the CPU.

## How these were measured

All 30 `npd-absent` fixtures in [eval/testdata](../eval/testdata/), at
prompt v4, with `--concurrency 1 --seed 1`, on an RTX 3070 with Ollama
0.40.6, thinking left at each model's default. The card also drove a
display, which left about 6.5 GB free, so none of the models fitted
entirely: Ollama ran 3 to 12 of each model's layers on the CPU. A card that
drives no display has more room and should be faster.

To reproduce, copy those fixture directories into a scratch directory and
run, for example:

```sh
TROPIS_CONTEXT_TOKENS=32768 tropis eval --corpus <dir> --backend local \
  --base-url http://localhost:11434 --model qwen3.5:9b \
  --concurrency 1 --seed 1 --timeout 15m
```

## Choosing

- **Data may leave and accuracy matters most:** claude.
- **Data may leave, and the cost of calling the default model for every
  candidate node matters more than some accuracy:** claude-sweep-escalate.
  Compare it with claude on your own nodes before relying on it.
- **Nothing may leave and you have a GPU of about 8 GB:** local-gpu-8gb. If
  you would rather a model said "cannot tell" than risk a wrong answer, try
  `granite4.2:8b` by setting `backend.model`. A larger GPU can run a larger
  model; check that `backend.contextTokens` still fits.

Tropis has no CPU-only profile: the small models tested on a CPU were too
slow and failed too often to recommend.

Do not set `backend.localThink: "false"` to speed up a local model. On the
dev corpus that made the model much faster but overconfident, and it made
false causal claims it did not make with thinking on.
