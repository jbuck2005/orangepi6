# Contributing

## Keep HISTORY.md up to date
[HISTORY.md](HISTORY.md) is the running record of every patch, change, release and finding. Update it in the same
commit or pull request as the change itself:

- a new or changed patch: its file name, what it does, and why
- a script or tooling change: the commit and what it changes for users
- a release: tag, kernel, the commit it is built from, and when it was published
- a finding from testing (a cause found, a test passed or failed, a dead end): what was seen and what it means

Add entries in date order under the right kernel line (6.18 LTS on `main`, or the experimental kernel 7 branch),
and update the "Open items" list when something is fixed or found.

## Board tests
Every test on the board follows [bench/TEST-PROCESS.md](bench/TEST-PROCESS.md): boot-persistent loggers,
temperatures on the serial console, pre-flight before every set and after every reboot, one log per run that is
never overwritten, logs copied off the board while the test runs, a record per run, and a status at most 15 minutes
apart.

## Other rules
- Commits are authored and committed by jbuck2005. No `Co-Authored-By` or other attribution trailers, in commits,
  pull requests or docs.
- Don't put LAN addresses, hostnames, tokens or other private details in commits, docs or logs.
- Patching is strict (no fuzz); refresh a patch rather than relying on fuzz.
