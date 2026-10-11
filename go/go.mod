module github.com/jonny-novikov/brd14/go

// The floor is real, not aspirational: the production files need 1.20
// (sync/atomic.Int64 is 1.19, ParseBytes's slice-to-array conversion 1.20),
// and the tests use math/rand/v2, which is 1.22. Nothing here uses a 1.23+
// feature — `make harden` runs the whole suite on go1.22.12 to prove it. A
// dependency's go line is a promise to its consumers, so it states the honest
// minimum rather than matching whatever the first consumer happens to declare.
go 1.22.0
