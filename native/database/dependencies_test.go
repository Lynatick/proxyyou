package configdb

import "testing"

func TestDependencyFingerprintInvalidatesTransitiveUsers(t *testing.T) {
	entries := []Entry{{Tag: "a", Type: "socks", Fingerprint: "one", Dependencies: []string{"b"}}, {Tag: "b", Type: "socks", Fingerprint: "two", Dependencies: []string{"c"}}, {Tag: "c", Type: "socks", Fingerprint: "three"}, {Tag: "unchanged", Type: "socks", Fingerprint: "stable"}}
	before, err := dependencyFingerprints(entries)
	if err != nil {
		t.Fatal(err)
	}
	entries[2].Fingerprint = "updated"
	after, err := dependencyFingerprints(entries)
	if err != nil {
		t.Fatal(err)
	}
	for _, tag := range []string{"a", "b", "c"} {
		if before[tag] == after[tag] {
			t.Fatal("stale dependant", tag)
		}
	}
	if before["unchanged"] != after["unchanged"] {
		t.Fatal("unrelated object invalidated")
	}
	entries[2].Dependencies = []string{"a"}
	if _, err = dependencyFingerprints(entries); err == nil {
		t.Fatal("cycle accepted")
	}
}
