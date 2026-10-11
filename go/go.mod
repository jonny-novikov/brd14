module github.com/jonny-novikov/brd14/go

// The floor is real, not aspirational: the production files need only 1.19
// (sync/atomic.Int64), but the contract vectors use math/rand/v2, which is
// 1.22. Nothing here uses a 1.23+ feature. A dependency's go line is a promise
// to its consumers, so it states the honest minimum rather than matching
// whatever the first consumer happens to declare.
go 1.22.0
