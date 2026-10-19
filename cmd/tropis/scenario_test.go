package main

import (
	"strings"
	"testing"

	"github.com/I-Am-Webbo/tropis/eval/scenarios"
)

func TestScenarioList(t *testing.T) {
	all, err := scenarios.Load()
	if err != nil {
		t.Fatal(err)
	}
	code, out, errOut := runCmd("scenario", "list")
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	ids := strings.Fields(out)
	if len(ids) != len(all) {
		t.Fatalf("listed %d scenarios, want %d", len(ids), len(all))
	}
	for i, s := range all {
		if ids[i] != s.ID {
			t.Errorf("line %d = %q, want %q", i, ids[i], s.ID)
		}
	}
}

func TestScenarioShow(t *testing.T) {
	code, out, errOut := runCmd("scenario", "show", "degradation-fsync")
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	for _, want := range []string{
		"SCENARIO_ID='degradation-fsync'\n",
		"FAULT_TYPE='disk.progressive_degradation'\n",
		"INJECT_SCRIPT='degradation.sh'\n",
		"INJECT_PARAMS='INTERVAL=120 STEP=8'\n", // sorted, so stable
		"INJECT_TARGET=''\n",
		"SYMPTOM_SCRIPT=''\n",
		"WORKLOAD='postgres-hostpath'\n",
		"HARDWARE='real-sata'\n",
		"EXPECT_SMART='reallocated_sectors'\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	// The driver never needs the answer, so it is not printed.
	for _, never := range []string{"causal", "EXPECTED", "SYNTHETIC", "realloc-growing"} {
		if strings.Contains(out, never) {
			t.Errorf("output contains %q:\n%s", never, out)
		}
	}

	_, out, _ = runCmd("scenario", "show", "pending-silent-137")
	for _, want := range []string{
		"SYMPTOM_SCRIPT='silent-kill.sh'\n",
		"SYMPTOM_PARAMS='APP=batch-reader INTERVAL=60 KILLS=3'\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	_, out, _ = runCmd("scenario", "show", "read-errors-batch")
	if !strings.Contains(out, "INJECT_TARGET='batch/dataset'\n") {
		t.Errorf("no target:\n%s", out)
	}
}

func TestScenarioShowUnknown(t *testing.T) {
	code, out, errOut := runCmd("scenario", "show", "no-such-scenario")
	if code == exitOK || out != "" || !strings.Contains(errOut, "no scenario") {
		t.Errorf("exit %d, stdout %q, stderr %q", code, out, errOut)
	}
	if code, _, _ := runCmd("scenario"); code != exitUsage {
		t.Errorf("no args: exit %d", code)
	}
}

func TestShellQuote(t *testing.T) {
	for in, want := range map[string]string{
		"":          `''`,
		"a b":       `'a b'`,
		"it's":      `'it'\''s'`,
		"$(rm -rf)": `'$(rm -rf)'`,
	} {
		if got := shellQuote(in); got != want {
			t.Errorf("shellQuote(%q) = %s, want %s", in, got, want)
		}
	}
}
