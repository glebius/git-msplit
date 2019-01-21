A script that produces same result that **git subtree split** does,
but processed multiple branches at one run and doesn't store any
metadata on the source branch. However, it allows you to start
future split starting at a point where previous one has finished.

### Usage

git-msplit.pl -m map-file [-d] [-c entries]
       [-s start-revision] [-r end-revision]

Map file is on entry per line. An entry consist of directory spec
and branch name to split it to.

By default script runs silently, so -d is strongly recommended.

By default script runs from beginning of history to HEAD.

Using -c allows to cache data in memory, which speeds up processing.

If resulting branch exists, then script assumes that a repeated
split is done. It will require -s to be present and will check
that current state of branches matches specified point.

### Performance notes

This script was designed to pull out individualt ports with history
out of [FreeBSD ports repo](https://github.com/freebsd/freebsd-ports).
At moment of this writing it has over 480 000 commits. To split a
single directory out of it **git subtree split** would take 1 - 4 hours,
depending on how powerful your CPU/mem is. Since it can't parallel
several subdirs, to split out 100 ports would take at least 4 days.

This script is able to split a single port within minutes and a
set of 100 ports within 3 hours.
