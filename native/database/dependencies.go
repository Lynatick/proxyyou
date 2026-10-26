package configdb

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// A changed detour also invalidates dependent idle protocol objects. Existing
// sockets keep their own generation; new objects resolve the new dependency.
func dependencyFingerprints(entries []Entry) (map[string]string, error) {
	byTag := make(map[string]Entry, len(entries))
	for _, entry := range entries {
		byTag[entry.Tag] = entry
	}
	result := make(map[string]string, len(entries))
	visiting := make(map[string]bool)
	var visit func(string) (string, error)
	visit = func(tag string) (string, error) {
		if value, ok := result[tag]; ok {
			return value, nil
		}
		if visiting[tag] {
			return "", fmt.Errorf("cyclic configuration dependency: %s", tag)
		}
		entry, ok := byTag[tag]
		if !ok {
			return "external:" + tag, nil
		}
		visiting[tag] = true
		hash := sha256.New()
		fmt.Fprintf(hash, "%d:%s%d:%s%d:%s", len(entry.Section), entry.Section, len(entry.Type), entry.Type, len(entry.Fingerprint), entry.Fingerprint)
		for _, dependency := range entry.Dependencies {
			value, err := visit(dependency)
			if err != nil {
				return "", err
			}
			fmt.Fprintf(hash, "%d:%s%d:%s", len(dependency), dependency, len(value), value)
		}
		delete(visiting, tag)
		value := hex.EncodeToString(hash.Sum(nil))
		result[tag] = value
		return value, nil
	}
	for _, entry := range entries {
		if _, err := visit(entry.Tag); err != nil {
			return nil, err
		}
	}
	return result, nil
}
