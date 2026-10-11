//go:build race

package brd14

// raceEnabled reports a -race build. The race runtime instruments memory
// accesses and can allocate where the plain build does not, so the allocation
// assertions in alloc_test.go skip under it: there they would measure the
// detector, not this package.
const raceEnabled = true
