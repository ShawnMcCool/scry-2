package updater

import (
	"fmt"
	"strings"
)

// IsNewer reports whether latest is a higher semver than current.
// Both must be in "vMAJOR.MINOR.PATCH" form; any parse error returns false.
func IsNewer(latest, current string) bool {
	lv, err := parseSemver(latest)
	if err != nil {
		return false
	}
	cv, err := parseSemver(current)
	if err != nil {
		return false
	}
	return lv[0] > cv[0] ||
		(lv[0] == cv[0] && lv[1] > cv[1]) ||
		(lv[0] == cv[0] && lv[1] == cv[1] && lv[2] > cv[2])
}

func parseSemver(v string) ([3]int, error) {
	v = strings.TrimPrefix(v, "v")
	var major, minor, patch int
	if _, err := fmt.Sscanf(v, "%d.%d.%d", &major, &minor, &patch); err != nil {
		return [3]int{}, fmt.Errorf("invalid semver %q: %w", v, err)
	}
	return [3]int{major, minor, patch}, nil
}
