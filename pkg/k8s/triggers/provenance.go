package triggers

import (
	"strings"

	corev1 "k8s.io/api/core/v1"
)

// kubernetesNodeReporters are the Kubernetes components whose events about a
// Node are evidence. Each is the component name the component passes to its
// event recorder in kubernetes/kubernetes:
//
//   - kubelet: pkg/kubelet/server ComponentKubelet (cmd/kubelet/app);
//     NodeHasDiskPressure, EvictionThresholdMet, ImageGCFailed and the like
//   - node-controller: the node lifecycle controller; NodeNotReady,
//     RegisteredNode
//   - cidrAllocator: the node IPAM range allocator; CIDRNotAvailable
//   - kube-proxy: cmd/kube-proxy/app; Starting
//
// This is an allowlist, like the kubelet's node conditions in pkg/k8s,
// rather than a denylist of node-problem-detector's names: NPD records every
// event under its monitor's configurable "source" (kernel-monitor,
// readonly-monitor, a custom plugin's own name), so no list of NPD names can
// be complete. Anything else that reports on the Node — in practice NPD — is
// not evidence. Changing this list changes the model input and needs a new
// PromptVersion.
var kubernetesNodeReporters = map[string]bool{
	"kubelet":         true,
	"node-controller": true,
	"cidrAllocator":   true,
	"kube-proxy":      true,
}

// TropisReporterPrefix starts the reporting controller of every event Tropis
// itself records (pkg/k8s EventNotifier). Those events carry Tropis's own
// verdicts and must never be read back as evidence.
const TropisReporterPrefix = "tropis.io/"

// EventReporter is the component that reported an event. Events recorded
// through events.k8s.io/v1 carry it only in reportingComponent; events from
// the core/v1 recorder carry it in source.component, and since client-go
// v0.19 in reportingComponent too.
func EventReporter(e corev1.Event) string {
	if e.ReportingController != "" {
		return e.ReportingController
	}
	return e.Source.Component
}

// FromTropis reports whether Tropis itself recorded the event.
func FromTropis(e corev1.Event) bool {
	return strings.HasPrefix(e.ReportingController, TropisReporterPrefix) ||
		strings.HasPrefix(e.Source.Component, TropisReporterPrefix)
}

// IsEvidence reports whether an event may reach the reasoning layer.
//
// Pod events are evidence whoever reported them: the kubelet, the scheduler
// and controllers all report on pods, and node-problem-detector never does
// (it records every event against the Node). Events about anything else,
// the Node above all, are evidence only from a Kubernetes component in
// kubernetesNodeReporters, so NPD's events — TaskHung, OOMKilling, one per
// condition change such as FilesystemIsReadOnly — are not, whatever source
// its monitors are configured with. Tropis's own events never are.
func IsEvidence(e corev1.Event) bool {
	if FromTropis(e) {
		return false
	}
	if e.InvolvedObject.Kind == "Pod" {
		return true
	}
	return kubernetesNodeReporters[EventReporter(e)]
}
