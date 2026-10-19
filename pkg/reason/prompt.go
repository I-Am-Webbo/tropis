package reason

import (
	_ "embed"
	"fmt"
)

// PromptVersion identifies what the model sees: the prompt below and the shape
// of the document BuildInput produces. Eval results are comparable only within
// a prompt version, so any change to either that could change model output
// must come with a new version (and, for the prompt, a new file) — never an
// edit in place.
//
// v2: prompt text identical to v1; trigger names (pre-filter rule IDs and NPD
// conditions) were removed from the model input.
//
// v3: host.unreadable also carries devices smartctl produced no output for
// (a drive that hung until the timeout), and the prompt says what a timeout
// means.
//
// v4: the prompt says that clean SMART does not clear the host storage path,
// that unreadable reasons other than a timeout say nothing about the disk,
// and that a workload causing its own storage eviction is causal at the
// kubernetes layer, not coincidental. The input document is unchanged.
//
// v5: prompt text identical to v4. kubernetes.events no longer carries
// node-problem-detector's Node events or Tropis's own: an event about the
// node is included only when a Kubernetes component reported it
// (triggers.IsEvidence). Pod events are unchanged.
const PromptVersion = "v5"

//go:embed prompts/v5.md
var systemPrompt string

// SystemPrompt returns the versioned system prompt. It is identical for every
// node, which is what makes it cacheable.
func SystemPrompt() string { return systemPrompt }

// UserMessage returns the per-node message: the redacted input document.
// It fails on any input not produced by BuildInput.
func UserMessage(in *AnalysisInput) (string, error) {
	text, err := in.Text()
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("Captured state of node %q follows.\n\n```json\n%s\n```", in.doc.Node, text), nil
}
