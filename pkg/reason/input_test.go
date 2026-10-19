package reason

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	"github.com/I-Am-Webbo/tropis/pkg/fixture"
	"github.com/I-Am-Webbo/tropis/pkg/host/prefilter"
	"github.com/I-Am-Webbo/tropis/pkg/schema"
)

var (
	capturedAt = time.Date(2026, 9, 20, 8, 0, 0, 0, time.UTC)
	earlier    = capturedAt.Add(-24 * time.Hour)
)

func mustJSON(t *testing.T, v any) schema.RawJSON {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func sample(t *testing.T, name string) schema.RawJSON {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "host", "smart", "testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// fakeStripeKey is assembled from two halves so the source never contains a
// string shaped like a live Stripe key, which secret scanners rightly reject.
const fakeStripeKey = "sk_" + "live_planted00000000000000000000"

// Secrets planted in every place a real capture can carry text. None may
// reach model input.
var planted = []string{
	"hunter2-db-password",
	"AKIAIOSFODNN7EXAMPLE",
	"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0cm9waXMtdGVzdCJ9.c2lnbmF0dXJlLXZhbHVl",
	"ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",
	"MIIEowIBAAKCAQEAplantedkeymaterial",
	"s3cr3t-in-url",
	"oncall@example.com",
	"10.20.30.40",
	"Z4Z1KQPL", // the failing sample's drive serial
	fakeStripeKey,
	"xoxb-000000000000-plantedslack",
	"annotation-secret-value",
	"label-token-value-123",
}

// plantedRequest builds a capture of a failing disk and a crash-looping
// database, with credentials planted throughout.
func plantedRequest(t *testing.T) Request {
	t.Helper()

	node := corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:        "worker-03",
			Labels:      map[string]string{"access_token": "label-token-value-123"},
			Annotations: map[string]string{"note": "contact oncall@example.com"},
		},
		Status: corev1.NodeStatus{Conditions: []corev1.NodeCondition{
			{Type: corev1.NodeReady, Status: corev1.ConditionTrue, Message: "kubelet is posting ready status from 10.20.30.40"},
			// An NPD condition in a hand-assembled fixture: must not appear.
			{Type: "ReadonlyFilesystem", Status: corev1.ConditionTrue, Reason: "FilesystemIsReadOnly"},
		}},
	}

	pod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:   "db",
			Name:        "postgres-0",
			Annotations: map[string]string{"api_key": "annotation-secret-value"},
		},
		Spec: corev1.PodSpec{
			NodeName: "worker-03",
			Containers: []corev1.Container{{
				Name: "postgres",
				Env: []corev1.EnvVar{
					{Name: "POSTGRES_PASSWORD", Value: "hunter2-db-password"},
					{Name: "AWS_ACCESS_KEY_ID", Value: "AKIAIOSFODNN7EXAMPLE"},
				},
				Resources: corev1.ResourceRequirements{
					Limits: corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("2Gi")},
				},
			}},
			Volumes: []corev1.Volume{{
				Name:         "data",
				VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{Path: "/mnt/disks/sdb/pg"}},
			}},
		},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			ContainerStatuses: []corev1.ContainerStatus{{
				Name:         "postgres",
				RestartCount: 14,
				State:        corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff"}},
			}},
		},
	}

	event := corev1.Event{
		ObjectMeta:     metav1.ObjectMeta{Namespace: "db", Name: "postgres-0.1", UID: "ev-1"},
		InvolvedObject: corev1.ObjectReference{Kind: "Pod", Namespace: "db", Name: "postgres-0"},
		Type:           "Warning",
		Reason:         "BackOff",
		Message:        "Back-off restarting failed container; notified oncall@example.com with token=ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",
		LastTimestamp:  metav1.NewTime(capturedAt.Add(-time.Minute)),
	}

	logs := strings.Join([]string{
		`2026-09-20T07:58:00Z LOG: connecting to postgres://replicator:s3cr3t-in-url@10.20.30.40:5432/app`,
		`2026-09-20T07:58:01Z LOG: auth header Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0cm9waXMtdGVzdCJ9.c2lnbmF0dXJlLXZhbHVl`,
		`2026-09-20T07:58:02Z LOG: loaded key -----BEGIN RSA PRIVATE KEY-----`,
		`MIIEowIBAAKCAQEAplantedkeymaterial`,
		`-----END RSA PRIVATE KEY-----`,
		`2026-09-20T07:58:03Z LOG: billing ` + fakeStripeKey + ` slack xoxb-000000000000-plantedslack`,
		`2026-09-20T07:58:04Z LOG: drive Z4Z1KQPL reported by operator`,
		`2026-09-20T07:58:11Z PANIC: could not fsync file "base/16384/2619": Input/output error`,
	}, "\n")

	return Request{
		Node: "worker-03",
		Host: schema.HostCapture{
			SMART:       map[string]schema.RawJSON{"/dev/sdb": sample(t, "sata-failing.json")},
			CollectedAt: capturedAt,
			Previous: &schema.HostSnapshot{
				SMART:       map[string]schema.RawJSON{"/dev/sdb": sample(t, "sata-failing.json")},
				CollectedAt: earlier,
			},
		},
		Kubernetes: schema.K8sCapture{
			NodeJSON:    mustJSON(t, node),
			Pods:        []schema.RawJSON{mustJSON(t, pod)},
			Events:      []schema.RawJSON{mustJSON(t, event)},
			Logs:        map[string]string{"db/postgres-0/postgres/previous": logs},
			CollectedAt: capturedAt,
		},
		TriggeredBy: []string{"smart.pending_sectors", "smart.health_failed"},
	}
}

// The non-negotiable test: a capture with planted credentials produces model
// input containing none of them — neither in the document nor in the full
// user message a backend sends.
func TestPlantedCredentialsNeverReachModelInput(t *testing.T) {
	in, err := BuildInput(plantedRequest(t))
	if err != nil {
		t.Fatalf("BuildInput: %v", err)
	}
	msg, err := UserMessage(in)
	if err != nil {
		t.Fatal(err)
	}
	text, _ := in.Text()

	for _, secret := range planted {
		for name, s := range map[string]string{"document": string(text), "user message": msg} {
			if strings.Contains(s, secret) {
				t.Errorf("planted secret %q reached the %s", secret, name)
			}
		}
	}

	// And the diagnostic content survived redaction.
	for _, keep := range []string{"could not fsync file", "Input/output error", "CrashLoopBackOff", "/mnt/disks/sdb/pg", "Reallocated_Sector_Ct"} {
		if !strings.Contains(msg, keep) {
			t.Errorf("diagnostic text %q should survive redaction", keep)
		}
	}
	if in.Redactions()["secret"] == 0 && in.Redactions()["url_credentials"] == 0 {
		t.Errorf("redaction summary shows nothing redacted: %v", in.Redactions())
	}
}

// NPD output is never evidence, even if a hand-assembled fixture leaves an
// NPD condition on the node or in npdConditions.
// NPD conditions are triggers, never evidence. They must not reach the model
// by any route: not as conditions, and not as the "npd.<Type>" trigger names
// the pre-filter derives from them. The triggers here are produced the way
// pipeline.Prefilter produces them, so a renamed trigger cannot slip past.
func TestNPDNeverReachesModelInput(t *testing.T) {
	req := plantedRequest(t)
	req.Kubernetes.NPDConditions = []schema.RawJSON{
		mustJSON(t, corev1.NodeCondition{Type: "KernelDeadlock", Status: "True"}),
		mustJSON(t, corev1.NodeCondition{Type: "ReadonlyFilesystem", Status: "True"}),
	}
	req.TriggeredBy = append(req.TriggeredBy, npdTriggers(t, req.Kubernetes.NPDConditions)...)
	if !containsPrefix(req.TriggeredBy, "npd.") {
		t.Fatalf("test setup: expected npd.* triggers, got %v", req.TriggeredBy)
	}

	in, err := BuildInput(req)
	if err != nil {
		t.Fatal(err)
	}
	assertNPDAbsent(t, in, "KernelDeadlock", "ReadonlyFilesystem")
}

// The same check against a corpus case where NPD is present: its
// ReadonlyFilesystem condition once reached the model as
// "triggeredBy": ["npd.ReadonlyFilesystem"].
func TestNPDNeverReachesModelInputFromFixture(t *testing.T) {
	f, err := fixture.LoadFixture(filepath.Join("..", "..", "eval", "testdata", "fs-corruption-readonly-npd-present"))
	if err != nil {
		t.Fatal(err)
	}
	if len(f.Kubernetes.NPDConditions) == 0 {
		t.Fatal("test setup: fixture should carry NPD conditions")
	}
	triggers := npdTriggers(t, f.Kubernetes.NPDConditions)
	if !containsPrefix(triggers, "npd.ReadonlyFilesystem") {
		t.Fatalf("test setup: expected npd.ReadonlyFilesystem, got %v", triggers)
	}

	in, err := BuildInput(RequestFromFixture(f, triggers))
	if err != nil {
		t.Fatal(err)
	}
	assertNPDAbsent(t, in, "ReadonlyFilesystem")
	if got := in.TriggeredBy(); len(got) != len(triggers) {
		t.Errorf("triggeredBy should still be recorded for the verdict: %v", got)
	}
}

// leakedEvents are events that must never reach the model: NPD's, under
// three of the sources its monitors use, and one of Tropis's own as the API
// server serves it through core/v1. Each carries a marker string.
func leakedEvents(t *testing.T, nodeName string) (events []schema.RawJSON, markers []string) {
	t.Helper()
	at := metav1.NewTime(capturedAt.Add(-10 * time.Minute))
	add := func(name, reason, msg string, src corev1.EventSource, controller string) {
		events = append(events, mustJSON(t, corev1.Event{
			ObjectMeta:          metav1.ObjectMeta{Namespace: "default", Name: name, UID: types.UID("uid-" + name)},
			InvolvedObject:      corev1.ObjectReference{Kind: "Node", Name: nodeName},
			Type:                "Warning",
			Reason:              reason,
			Message:             msg,
			Source:              src,
			ReportingController: controller,
			LastTimestamp:       at,
		}))
		markers = append(markers, reason, "uid-"+name)
	}
	npd := func(source string) corev1.EventSource { return corev1.EventSource{Component: source, Host: nodeName} }
	add("npd-hung", "TaskHung", "task jbd2/sdb1-8:412 blocked for more than 120 seconds.", npd("kernel-monitor"), "kernel-monitor")
	add("npd-ro", "FilesystemIsReadOnly", `Node condition ReadonlyFilesystem is now: True, reason: FilesystemIsReadOnly, message: "Remounting filesystem read-only"`, npd("kernel-monitor"), "kernel-monitor")
	add("npd-plugin", "SmartPendingSectors", "sdb: 24 pending sectors", npd("smart-custom-plugin-monitor"), "")
	add("tropis-own", "TropisCausalVerdict", "worker-03: causal (host). Tropis has taken no action; see the NodeHealthReport.", corev1.EventSource{}, "tropis.io/sweep")
	markers = append(markers, "jbd2", "Remounting filesystem", "pending sectors", "Tropis has taken no action")
	return events, markers
}

// assertAbsent checks the document and the full user message for markers.
func assertAbsent(t *testing.T, in *AnalysisInput, markers []string) {
	t.Helper()
	text, err := in.Text()
	if err != nil {
		t.Fatal(err)
	}
	msg, err := UserMessage(in)
	if err != nil {
		t.Fatal(err)
	}
	for name, s := range map[string]string{"document": string(text), "user message": msg} {
		for _, m := range markers {
			if strings.Contains(s, m) {
				t.Errorf("%q reached the %s", m, name)
			}
		}
	}
}

// NPD reports through Node events as well as conditions, and Tropis records
// its verdicts as Node events. Neither may reach the model: not from
// npdEvents, where the collector puts NPD's, and not from events, where an
// older or hand-assembled capture may still hold them. A kubelet event about
// the node still does.
func TestNPDEventsNeverReachModelInput(t *testing.T) {
	req := plantedRequest(t)
	leaked, markers := leakedEvents(t, req.Node)
	kubelet := mustJSON(t, corev1.Event{
		ObjectMeta:     metav1.ObjectMeta{Namespace: "default", Name: "worker-03.kubelet", UID: "ev-kubelet"},
		InvolvedObject: corev1.ObjectReference{Kind: "Node", Name: req.Node},
		Type:           "Warning",
		Reason:         "FreeDiskSpaceFailed",
		Message:        "failed to garbage collect required amount of images",
		Source:         corev1.EventSource{Component: "kubelet", Host: req.Node},
		LastTimestamp:  metav1.NewTime(capturedAt.Add(-5 * time.Minute)),
	})
	req.Kubernetes.Events = append(append(req.Kubernetes.Events, leaked...), kubelet)
	req.Kubernetes.NPDEvents = leaked

	in, err := BuildInput(req)
	if err != nil {
		t.Fatal(err)
	}
	assertAbsent(t, in, markers)
	text, _ := in.Text()
	for _, keep := range []string{"FreeDiskSpaceFailed", "event:ev-kubelet", "Back-off restarting failed container"} {
		if !strings.Contains(string(text), keep) {
			t.Errorf("Kubernetes event %q should still reach the model", keep)
		}
	}
	// Citing a dropped event is citing something the model never saw.
	if _, ok := in.lookupRef("event:uid-npd-ro"); ok {
		t.Error("a dropped NPD event is still citable")
	}
}

// The same against a corpus case where NPD is present: its npdEvents hold
// NPD's FilesystemIsReadOnly event. The fixture is checked as stored, and
// again with every NPD and Tropis event moved into events, as a capture
// taken before the collector split them would hold them.
func TestNPDEventsNeverReachModelInputFromFixture(t *testing.T) {
	f, err := fixture.LoadFixture(filepath.Join("..", "..", "eval", "testdata", "fs-corruption-readonly-npd-present"))
	if err != nil {
		t.Fatal(err)
	}
	if len(f.Kubernetes.NPDEvents) == 0 {
		t.Fatal("test setup: fixture should carry NPD events")
	}
	triggers := npdTriggers(t, f.Kubernetes.NPDConditions)
	markers := []string{"FilesystemIsReadOnly", "Node condition ReadonlyFilesystem"}

	in, err := BuildInput(RequestFromFixture(f, triggers))
	if err != nil {
		t.Fatal(err)
	}
	assertAbsent(t, in, markers)
	before, _ := in.Text()

	leaked, more := leakedEvents(t, f.Node)
	f.Kubernetes.Events = append(append(f.Kubernetes.Events, f.Kubernetes.NPDEvents...), leaked...)
	in, err = BuildInput(RequestFromFixture(f, triggers))
	if err != nil {
		t.Fatal(err)
	}
	assertAbsent(t, in, append(markers, more...))
	assertNPDAbsent(t, in, "ReadonlyFilesystem")
	if after, _ := in.Text(); string(after) != string(before) {
		t.Error("NPD and Tropis events in events changed the model input")
	}
}

// No trigger name of any kind reaches the model: a node arriving
// pre-labelled primes it towards "causal". The verdict still records them.
func TestTriggerNamesNeverReachModelInput(t *testing.T) {
	triggers := []string{
		prefilter.RuleHealthFailed,
		prefilter.RulePendingSectors,
		prefilter.RuleReallocatedGrowth,
		"k8s.storage_error",
		"npd.ReadonlyFilesystem",
	}
	req := plantedRequest(t)
	req.TriggeredBy = triggers

	in, err := BuildInput(req)
	if err != nil {
		t.Fatal(err)
	}
	text, err := in.Text()
	if err != nil {
		t.Fatal(err)
	}
	msg, err := UserMessage(in)
	if err != nil {
		t.Fatal(err)
	}
	for name, s := range map[string]string{"document": string(text), "user message": msg, "system prompt": SystemPrompt()} {
		if strings.Contains(s, "triggeredBy") {
			t.Errorf("the %s carries a triggeredBy field", name)
		}
		for _, id := range triggers {
			if strings.Contains(s, id) {
				t.Errorf("trigger %s reached the %s", id, name)
			}
		}
	}

	v, err := Finalize([]byte(validCausal), in, testInfo)
	if err != nil {
		t.Fatal(err)
	}
	if len(v.TriggeredBy) != len(triggers) {
		t.Errorf("verdict should still carry every trigger: %v", v.TriggeredBy)
	}
	for _, id := range triggers {
		if !containsPrefix(v.TriggeredBy, id) {
			t.Errorf("verdict lost trigger %s: %v", id, v.TriggeredBy)
		}
	}
}

// npdTriggers derives trigger names from raw NPD conditions as
// pipeline.Prefilter does. pipeline cannot be imported here: it imports reason.
func npdTriggers(t *testing.T, raw []schema.RawJSON) []string {
	t.Helper()
	var conds []prefilter.NPDCondition
	for _, r := range raw {
		var c prefilter.NPDCondition
		if err := json.Unmarshal(r, &c); err != nil {
			t.Fatal(err)
		}
		conds = append(conds, c)
	}
	var res prefilter.Result
	res.ApplyNPD(conds)
	return res.TriggeredBy()
}

func containsPrefix(list []string, prefix string) bool {
	for _, s := range list {
		if strings.HasPrefix(s, prefix) {
			return true
		}
	}
	return false
}

// assertNPDAbsent checks both the document and the full user message a
// backend sends.
func assertNPDAbsent(t *testing.T, in *AnalysisInput, conditionTypes ...string) {
	t.Helper()
	text, err := in.Text()
	if err != nil {
		t.Fatal(err)
	}
	msg, err := UserMessage(in)
	if err != nil {
		t.Fatal(err)
	}
	for name, s := range map[string]string{"document": string(text), "user message": msg} {
		if strings.Contains(s, "npd.") {
			t.Errorf("an npd.* trigger reached the %s", name)
		}
		for _, ct := range conditionTypes {
			if strings.Contains(s, ct) {
				t.Errorf("NPD condition %s reached the %s", ct, name)
			}
		}
	}
}

func TestBuildInputIsDeterministic(t *testing.T) {
	a, err := BuildInput(plantedRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	b, err := BuildInput(plantedRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	if a.Digest() != b.Digest() {
		t.Errorf("same capture produced different digests: %s vs %s", a.Digest(), b.Digest())
	}
	if !strings.HasPrefix(a.Digest(), "sha256:") {
		t.Errorf("digest = %q", a.Digest())
	}
}

func TestBuildInputContent(t *testing.T) {
	in, err := BuildInput(plantedRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	doc, err := in.Document()
	if err != nil {
		t.Fatal(err)
	}

	if len(doc.Host.Devices) != 1 {
		t.Fatalf("devices = %d", len(doc.Host.Devices))
	}
	dev := doc.Host.Devices[0]
	if dev.Previous == nil || *dev.Previous.ReallocatedSectors != 1544 {
		t.Errorf("previous reading should be attached: %+v", dev.Previous)
	}
	if doc.Host.PreviousCollectedAt == nil || !doc.Host.PreviousCollectedAt.Equal(earlier) {
		t.Errorf("previousCollectedAt = %v", doc.Host.PreviousCollectedAt)
	}

	if len(doc.Kubernetes.Pods) != 1 {
		t.Fatalf("pods = %d", len(doc.Kubernetes.Pods))
	}
	p := doc.Kubernetes.Pods[0]
	if p.Containers[0].RestartCount != 14 || !strings.Contains(p.Containers[0].State, "CrashLoopBackOff") {
		t.Errorf("container = %+v", p.Containers[0])
	}
	if p.Containers[0].Limits["memory"] != "2Gi" {
		t.Errorf("limits = %v", p.Containers[0].Limits)
	}
	if len(p.Volumes) != 1 || p.Volumes[0].Kind != "hostPath" {
		t.Errorf("volumes = %+v", p.Volumes)
	}

	if doc.Node != "worker-03" || in.Node() != "worker-03" {
		t.Errorf("node = %q / %q", doc.Node, in.Node())
	}
	if !in.ObservedAt().Equal(capturedAt) {
		t.Errorf("observedAt = %v", in.ObservedAt())
	}
	if got := in.TriggeredBy(); len(got) != 2 || got[0] != "smart.health_failed" {
		t.Errorf("triggeredBy should be sorted: %v", got)
	}

	// Env vars and annotations are not in the document at all.
	text, _ := in.Text()
	for _, absent := range []string{"POSTGRES_PASSWORD", "AWS_ACCESS_KEY_ID", "annotations", "serialNumber"} {
		if strings.Contains(string(text), absent) {
			t.Errorf("%q should not be in the document", absent)
		}
	}
}

// A drive smartctl hung on has no SMART output, but must still reach the
// model as unreadable, citable like any other device.
func TestCollectionFailureReachesModelInput(t *testing.T) {
	req := plantedRequest(t)
	req.Host.Unreadable = map[string]schema.CollectionFailure{
		"/dev/sdc": {Reason: "timeout", Detail: "context deadline exceeded: signal: killed"},
	}
	in, err := BuildInput(req)
	if err != nil {
		t.Fatal(err)
	}
	doc, _ := in.Document()
	if len(doc.Host.Unreadable) != 1 {
		t.Fatalf("unreadable = %+v, want the hung drive", doc.Host.Unreadable)
	}
	if u := doc.Host.Unreadable[0]; u.Ref != "smart:/dev/sdc" || u.Reason != "timeout" {
		t.Errorf("unreadable = %+v", u)
	}
	if _, ok := in.lookupRef("smart:/dev/sdc"); !ok {
		t.Error("the hung drive should be citable")
	}
}

// Nodes named by IP keep their real name on the verdict; only the model's
// view is redacted.
func TestNodeNamedByIP(t *testing.T) {
	req := plantedRequest(t)
	req.Node = "10.0.0.5"
	in, err := BuildInput(req)
	if err != nil {
		t.Fatal(err)
	}
	if in.Node() != "10.0.0.5" {
		t.Errorf("Node() = %q, want the real name", in.Node())
	}
	msg, _ := UserMessage(in)
	if strings.Contains(msg, "10.0.0.5") {
		t.Error("the model's view should carry the redacted node name")
	}
}

func TestUnbuiltInputIsRejected(t *testing.T) {
	var in AnalysisInput
	if _, err := UserMessage(&in); !errors.Is(err, ErrUnbuiltInput) {
		t.Errorf("UserMessage on a zero input: %v", err)
	}
	if _, err := in.Text(); !errors.Is(err, ErrUnbuiltInput) {
		t.Errorf("Text on a zero input: %v", err)
	}
	if _, err := Finalize([]byte(`{}`), &in, schema.BackendInfo{}); !errors.Is(err, ErrUnbuiltInput) {
		t.Errorf("Finalize on a zero input: %v", err)
	}
}

func TestBuildInputRequiresNode(t *testing.T) {
	if _, err := BuildInput(Request{}); err == nil {
		t.Error("expected an error for a request without a node")
	}
}

func TestPromptIsVersionedAndStable(t *testing.T) {
	p := SystemPrompt()
	if len(p) < 1000 {
		t.Fatalf("system prompt looks empty or truncated: %d bytes", len(p))
	}
	for _, must := range []string{"coincidental", "insufficient_evidence", "causal", "read-only"} {
		if !strings.Contains(p, must) {
			t.Errorf("system prompt should mention %q", must)
		}
	}
	// The system prompt is the cacheable prefix: it must not vary per call.
	if SystemPrompt() != p {
		t.Error("system prompt is not stable")
	}
	if PromptVersion == "" {
		t.Error("prompt version must be set")
	}
}
