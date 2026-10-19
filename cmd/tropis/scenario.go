package main

import (
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/I-Am-Webbo/tropis/eval/scenarios"
)

func init() {
	commands["scenario"] = command{"list scenarios and print one for the capture driver", runScenario}
}

const scenarioUsage = `usage:
  tropis scenario list         print every scenario id, one per line
  tropis scenario show <id>    print one scenario as shell assignments

show prints what hack/capture/run-scenario.sh needs to drive a capture,
read from the scenarios built into this binary, so a script never parses
scenarios.yaml itself:

  SCENARIO_ID SCENARIO_DESCRIPTION FAULT_TYPE INJECT_SCRIPT INJECT_PARAMS
  INJECT_TARGET SYMPTOM_SCRIPT SYMPTOM_PARAMS WORKLOAD HARDWARE EXPECT_SMART

Lists are space-separated, and params are NAME=value pairs. Every value is
single-quoted, ready for eval. Expected answers and synthetic hints are not
printed: nothing on the rig needs them.
`

func runScenario(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, scenarioUsage)
		return exitUsage
	}
	all, err := scenarios.Load()
	if err != nil {
		return fail(stderr, "%v", err)
	}
	switch {
	case args[0] == "list" && len(args) == 1:
		for _, s := range all {
			fmt.Fprintln(stdout, s.ID)
		}
		return exitOK
	case args[0] == "show" && len(args) == 2:
		s, err := scenarios.Find(all, args[1])
		if err != nil {
			return fail(stderr, "%v", err)
		}
		fmt.Fprint(stdout, shellAssignments(s))
		return exitOK
	default:
		fmt.Fprint(stderr, scenarioUsage)
		return exitUsage
	}
}

// shellAssignments renders a scenario as NAME='value' lines.
func shellAssignments(s scenarios.Scenario) string {
	var injectScript, injectParams, injectTarget, symptomScript, symptomParams string
	if s.Inject != nil {
		injectScript, injectParams, injectTarget = s.Inject.Script, pairs(s.Inject.Params), s.Inject.Target
	}
	if s.Symptom != nil {
		symptomScript, symptomParams = s.Symptom.Script, pairs(s.Symptom.Params)
	}
	vars := []struct{ name, value string }{
		{"SCENARIO_ID", s.ID},
		{"SCENARIO_DESCRIPTION", strings.Join(strings.Fields(s.Description), " ")},
		{"FAULT_TYPE", s.FaultType},
		{"INJECT_SCRIPT", injectScript},
		{"INJECT_PARAMS", injectParams},
		{"INJECT_TARGET", injectTarget},
		{"SYMPTOM_SCRIPT", symptomScript},
		{"SYMPTOM_PARAMS", symptomParams},
		{"WORKLOAD", s.Workload},
		{"HARDWARE", strings.Join(s.Hardware, " ")},
		{"EXPECT_SMART", strings.Join(s.ExpectSMART, " ")},
	}
	var b strings.Builder
	for _, v := range vars {
		fmt.Fprintf(&b, "%s=%s\n", v.name, shellQuote(v.value))
	}
	return b.String()
}

// pairs renders params as sorted NAME=value pairs. Validate keeps names and
// values free of anything that would need quoting.
func pairs(params map[string]string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]string, len(keys))
	for i, k := range keys {
		out[i] = k + "=" + params[k]
	}
	return strings.Join(out, " ")
}

// shellQuote single-quotes s for a POSIX shell.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
