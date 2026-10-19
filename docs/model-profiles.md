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

| Profile | Hardware | What leaves the cluster | Time per analysed node | Dev-corpus behaviour (30 cases, prompt v4) | Caveats |
|---|---|---|---|---|---|
| [claude](../deploy/helm/tropis/examples/claude.yaml) | None; an Anthropic API key in a Secret | The redacted evidence of each node the pre-filter raises, sent to Anthropic ([SECURITY.md](../SECURITY.md#what-leaves-the-cluster)) | Not yet measured | Not yet measured | The chart's default |
| [claude-sweep-escalate](../deploy/helm/tropis/examples/claude-sweep-escalate.yaml) | As claude | As claude, sent once or twice per node | Not yet measured | Not yet measured | Cheaper and less accurate: a sweep that is confidently wrong is never escalated |
| [local-gpu-8gb](../deploy/helm/tropis/examples/local-gpu-8gb.yaml) | A GPU with 8 GB that drives no display, running Ollama with `qwen3.5:9b` (6.6 GB) | Nothing | About 1.5 min (RTX 3070) | 16/20 detected end to end; 0/6 false causal claims; 1 error; `insufficient_evidence` correct 3/4 | Needs most of an 8 GB card: see [Fitting the GPU](#fitting-the-gpu) |

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

- **A difference of two cases is noise.** Tropis asks for deterministic
  output (temperature 0), but a model's long hidden reasoning is sensitive
  to tiny numerical differences. The same model, prompt and settings,
  once with part of the model on the CPU and once entirely on the GPU,
  scored 18/20 and 16/20, with five cases changing answer in both
  directions.
- **The corpus cannot catch over-claiming.** It has no negative control in
  which a workload shows disk-like symptoms (a read-only filesystem, I/O
  errors) that the disk did not cause. A model that says `causal` too
  readily on such symptoms would not be penalised here.
- **Nine of the thirty cases informed prompt v4.** Prompt v4 was written
  after looking at nine cases that v3 got wrong or nearly wrong. On the 21
  cases not looked at, qwen3.5:9b improved from 14 to 18 correct between v3
  and v4 at the same settings, so the change was not only fitted to the nine.

## Other models that fit an 8 GB GPU

Measured the same way. Only the first row ran entirely on the GPU; the
others ran 3 to 12 of the model's layers on the CPU, which makes them
slower than they would be on a card with room for the whole model.

| Model | Download | Context | Detected end to end | False causal claims | Errors | `insufficient_evidence` correct | Whole corpus |
|---|---|---|---|---|---|---|---|
| `qwen3.5:9b` (the profile) | 6.6 GB | 32768 | 16/20 | 0/6 | 1 | 3/4 | 43m |
| `qwen3.5:9b`, part on the CPU | 6.6 GB | 32768 | 18/20 | 0/6 | 1 | 2/4 | 1h39m |
| `qwen3.5:9b`, part on the CPU | 6.6 GB | 16384 | 16/20 | 0/6 | 2 | 2/4 | 1h01m |
| `gemma4:12b-it-qat`, part on the CPU | 7.2 GB | 16384 | 16/20 | 0/6 | 2 | 2/4 | 1h06m |
| `granite4.2:8b`, part on the CPU | 5.3 GB | 16384 | 13/20 | 0/6 | 0 | 4/4 | 1h26m |

- **gemma4:12b-it-qat** scores like qwen3.5:9b, but at 7.2 GB it cannot
  run entirely on an 8 GB card with a useful context window.
- **granite4.2:8b** is the most cautious. It never failed to give a
  verdict and was the only model to answer every "cannot tell" case
  correctly, but it said `insufficient_evidence` on three real faults and
  missed more of them.

The cases any of them got wrong:

| Case | Truth | qwen3.5:9b (profile) | qwen3.5:9b, 32768, part CPU | qwen3.5:9b, 16384 | gemma4:12b | granite4.2:8b |
|---|---|---|---|---|---|---|
| exhaustion-emptydir | causal, kubernetes | ✓ | ✓ | coincidental ✗ | ✓ | coincidental ✗ |
| exhaustion-log-spam | causal, kubernetes | coincidental ✗ | ✓ | ✓ | coincidental ✗ | coincidental ✗ |
| fs-corruption-app-errors | causal, host | ✓ | ✓ | ✓ | ✓ | insufficient_evidence ✗ |
| fs-corruption-readonly | causal, host | ✓ | ✓ | error ✗ | ✓ | ✓ |
| io-timeout-log-writer | causal, host | ✓ | ✓ | ✓ | ✓ | coincidental ✗ |
| io-timeout-postgres-probes | causal, host | ✓ | error ✗ | ✓ | ✓ | ✓ |
| pending-no-symptoms | insufficient_evidence | ✓ | ✓ | ✓ | error ✗ | ✓ |
| pending-silent-137 | insufficient_evidence | ✓ | coincidental ✗ | coincidental ✗ | coincidental ✗ | ✓ |
| read-errors-with-stable-defects | causal, host | ✓ | ✓ | ✓ | error ✗ | ✓ |
| unreadable-smart-restarts | insufficient_evidence | coincidental ✗ | coincidental ✗ | error ✗ | ✓ | ✓ |
| write-errors-postgres | causal, host | ✓ | ✓ | ✓ | ✓ | insufficient_evidence ✗ |
| write-errors-readonly-remount | causal, host | error ✗ | ✓ | ✓ | ✓ | insufficient_evidence ✗ |

Every error was the model's hidden reasoning running on until it filled the
context window or hit the request timeout. The profile sets 32768 so that
reasoning has room to finish; at 16384, qwen3.5:9b ran out of room twice.

Not measured: newer and larger models (Qwen 3.6 and later, `gpt-oss:20b`,
26–35B mixture-of-experts models) are bigger than an 8 GB card can hold
without running mostly on the CPU.

## Fitting the GPU

The profile needs about 7.3 GB of GPU memory: 6.6 GB for the model and the
rest for a 32768-token context. On an 8 GB card that leaves little spare,
and two things can push part of the model onto the CPU, which made it
about 2.3 times slower in testing:

- **A display.** A card that also drives a desktop loses about 1 GB to it.
  Use a card that drives no display, or plug the monitor into another
  GPU.
- **Ollama's safety margin.** By default Ollama's loader keeps about 1.9 GB
  of the card free, and runs layers on the CPU rather than use it. Set
  `LLAMA_ARG_FIT_TARGET=512` (MiB) in the Ollama server's environment to
  keep 512 MiB free instead, then restart Ollama. Leave the card to
  Ollama alone: with a small margin, another process allocating GPU
  memory can make a model load fail or fall back to the CPU.

`ollama ps` shows where a loaded model runs: `100% GPU` means it fitted.

## How these were measured

All 30 `npd-absent` fixtures in [eval/testdata](../eval/testdata/), at
prompt v4, not yet re-run at the current prompt, v5. v5 keeps v4's prompt
text and only removes node-problem-detector's and Tropis's own Node events
from the model input; none of these fixtures carries either, and their
input digests are the same at v5, so the numbers are expected to carry over,
but they are v4 measurements until re-measured. They were taken with
`--concurrency 1 --seed 1`, on an RTX 3070 with Ollama 0.40.6, thinking left at each model's default. The profile's run used a
card that drove no display and `LLAMA_ARG_FIT_TARGET=512`; the other runs
were made before those changes.

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
