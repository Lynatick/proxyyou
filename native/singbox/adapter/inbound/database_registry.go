package inbound

import "sort"

// OptionTypes allows the typed relational codec to register concrete unions.
func (r *Registry) OptionTypes() []string {
	r.access.Lock()
	defer r.access.Unlock()
	result := make([]string, 0, len(r.optionsType))
	for name := range r.optionsType {
		result = append(result, name)
	}
	sort.Strings(result)
	return result
}
