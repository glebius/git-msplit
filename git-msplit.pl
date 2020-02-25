#!/usr/local/bin/perl -wT

use strict;

use Getopt::Std;
use IPC::Open2;

$ENV{PATH} = "";

use constant GIT	=> '/usr/local/bin/git';
use constant HRE	=> '^([0-9a-f]{40})$';
use constant TRE	=> '^([0-7]{5,6}) (.+?)\0(.{20})';
use constant ARE	=> '^(.*) <([^>]+)> ([0-9]+) \+0000$';

sub debug;
sub readmap();
sub checkmap($$);
sub checkdeleted($$);
sub readallcommits();
sub readcommit($);
sub readtree($);
sub append($$$);
sub processtree($$$);
sub updaterefs($);

my %opts;
getopts("c:dm:r:s:", \%opts);
unless (defined($opts{m})) {
	printf("Usage: %s -m map-file [-d] [-c entries]\n", $0);
	printf("       [-s start-revision] [-r end-revision]\n");
	exit(0);
}

if (defined($opts{r})) {
	# XXXGL: not a true git-check-ref-format
	die("Bad reference name $opts{r}")
		unless($opts{r} =~ /^([\w\/.-]+)$/);
	$opts{r} = $1;
} else {
	$opts{r} = "HEAD";
}

my %map;	# map of what to split
my @allcommits;	# history to run through
my ($pid, $rd, $wr); # spawned 'git cat-file --batch'
my $cache;	# cache of tree object

if (defined($opts{c})) {
	require Cache::LRU;
	$cache = Cache::LRU->new(size => $opts{c});
}

# Open the main workhorse to read data
$pid = open2($rd, $wr, &GIT, 'cat-file', '--batch');
die("open2(): $!") unless (defined $pid);

readmap();
if (defined($opts{s})) {
	# XXXGL: not a true git-check-ref-format
	die("Bad reference name $opts{s}")
		unless($opts{s} =~ /^([\w\/.-]+)$/);
	$opts{s} = $1;
	# Make sure that existing branches match tree state ar start point
	checkmap(\%map, readtree(%{readcommit($opts{s})}{tree}));
}
readallcommits();

$ENV{TZ} = "";

my $n = 0;
foreach my $hash (@allcommits) {
	my $commit;
	my $tree;

	$commit = readcommit($hash);
	$tree = readtree($commit->{tree});

	processtree($commit, $tree, \%map);
	debug("%d/%d\r", $n++, $#allcommits);
}
updaterefs(\%map);
debug("Split finished at %s\n", $allcommits[-1]);
checkdeleted(\%map, readtree(%{readcommit($allcommits[-1])}{tree}));
close($wr);
waitpid($pid, 0);
exit 0;

sub debug
{
	printf(@_) if defined($opts{d});
}

# Init: parse map file
sub readmap() {
	my $mapfd;
	my $branches = 0;

	die("Can't open $opts{m}: $!\n") unless (open($mapfd, '<', $opts{m}));

	while (<$mapfd>) {
		my (@line, @dirs, $dir);

		chomp;
		@line = split(/ +/);
		die("Can't parse: $_\n") unless ($#line == 1);
		@dirs = split(/\//, $line[0]);

		$dir = \%map;
		for (my $d = 0; $d <= $#dirs; $d++) {
			if ($d == $#dirs) {
				my ($hash, $tree);

				# XXXGL: this doesn't match # what git
				# imposes on branch name.
				die("Bad branch name $line[1]")
					unless($line[1] =~ /^([\w\/.-]+)$/);
				$line[1] = $1;
				$hash = readbranch($line[1]);
				debug("%s branch %s\n", defined($hash) ?
				    "Existing" : "New", $line[1]);
				if (defined($hash)) {
					die("No start revision and existing ".
					    "branch $line[1]")
						unless defined($opts{s});
					$tree = %{readcommit($hash)}{tree};
				} else {
					$tree = undef;
				}
				$dir->{branches}->{$dirs[$d]} = {
					name => $line[1],
					head => $hash,
					tree => $tree,
				};
				$branches++;
			} else {
				if (not defined($dir->{dirs}->{$dirs[$d]})) {
					$dir->{dirs}->{$dirs[$d]} = {};
				};
				$dir = $dir->{dirs}->{$dirs[$d]};
			}
		}
	}
	close($mapfd);
	debug("Read %d branches from map\n", $branches);
}

sub checkmap($$) {
	my ($map, $tree) = @_;

	foreach my $dir (keys(%{$map->{branches}})) {
		if (defined($map->{branches}->{$dir}->{head})) {
			die("Specified $map->{branches}->{$dir}->{name} ".
			    "doesn't exist at $opts{s}")
				unless(defined($tree->{$dir}));
			die("Existing $map->{branches}->{$dir}->{name} ".
			    "does not match tree state at $opts{s}: ".
			    "expected tree $tree->{$dir}")
				unless($map->{branches}->{$dir}->{tree} eq
				    $tree->{$dir});
			debug("Branch %s to be appended at %s\n",
			    $map->{branches}->{$dir}->{name},
			    $map->{branches}->{$dir}->{head});
		}
	}
	foreach my $dir (keys(%{$map->{dirs}})) {
		checkmap($map->{dirs}->{$dir}, readtree($tree->{$dir}));
	}
}

sub checkdeleted($$) {
	my ($map, $tree) = @_;

	foreach my $dir (keys(%{$map->{branches}})) {
		if (defined($map->{branches}->{$dir}->{head}) &&
		    not defined($tree->{$dir})) {
			debug("Directory corresponding to %s no longer ".
			    "exist at %s\n",
			    $map->{branches}->{$dir}->{name},
			    $allcommits[-1]);
		}
	}
	foreach my $dir (keys(%{$map->{dirs}})) {
		checkdeleted($map->{dirs}->{$dir}, readtree($tree->{$dir}));
	}
}

# Resolve existing branch
sub readbranch($) {
	my $name = shift;
	my ($pid, $rd, $wr);
	my $hash;

	$pid = open2($rd, $wr, &GIT, 'rev-parse', '--verify', '-q', $name);
	die("open2(): $!") unless (defined $pid);
	$hash = <$rd>;
	return undef
		unless defined($hash);
	die("Bad output from write-tree $hash")
		unless($hash =~ &HRE);
	$hash = $1;
	waitpid($pid, 0);

	return $hash;
}

# Init: populate history that we are going to process
sub readallcommits() {
	my ($pid, $rd, $wr);
	my @args;

	@args = (&GIT, 'rev-list', '--reverse', $opts{r});
	if (defined($opts{s})) {
		push(@args, "^" . $opts{s});
	}
	$pid = open2($rd, $wr, @args);
	die("open2(): $!") unless (defined $pid);

	while (<$rd>) {
		die("Bad data in $_")
			unless ($_ =~ &HRE);
		push(@allcommits, $1);
	}
	waitpid($pid, 0);
}

# Return $commit object for a given hash
sub readcommit($) {
	my $hash = shift;
	my (@header, $text);
	my $commit;

	printf($wr "%s\n", $hash);
	@header = split(/ /, readline($rd));

	die("Unexpected input @header")
		unless($header[0] eq $hash && $header[1] eq "commit");

	die("read(): $!")
		unless(read($rd, $text, $header[2]) == $header[2]);

	my $inbody = 0;
	for (split /^/, $text) {

		unless ($inbody) {
			my ($key, $val);

			chomp;
			($key, $val) = split(/ /, $_, 2);

			if (not defined($key)) {
				$inbody = "true";
				next;
			}
			if ($key eq "tree") {
				die("Bad data in $val")
					unless($val =~ &HRE);
				$commit->{tree} = $1;
				next;
			}
			if ($key eq "parent") {
				die("Bad data in $val")
					unless($val =~ &HRE);
				$commit->{parent} = $1;
				next;
			}
			if ($key eq "author") {
				die("Bad data in $val")
					unless($val =~ &ARE);
				$commit->{a_name} = $1;
				$commit->{a_email} = $2;
				$commit->{a_date} = $3;
				next;
			}
			if ($key eq "committer") {
				die("Bad data in $val")
					unless($val =~ &ARE);
				$commit->{c_name} = $1;
				$commit->{c_email} = $2;
				$commit->{c_date} = $3;
				next;
			}
		}
		$commit->{log} .= $_;
	}
	readline($rd);	# Eat extra LF from git cat-file --batch

	return $commit;
}

# Return $tree object for a given hash
sub readtree($) {
	my $hash = shift;
	my (@header, $text);
	my $tree;

	if (defined($cache) && defined($tree = $cache->get($hash))) {
		return $tree;
	}

	printf($wr "%s\n", $hash);
	@header = split(/ /, readline($rd));

	die("Unexpected input @header")
		unless($header[0] eq $hash && $header[1] eq "tree");

	die("read(): $!")
		unless(read($rd, $text, $header[2]) == $header[2]);

	while ($text) {
		die("Bad data in tree $hash: $text")
			unless($text =~ s/${\TRE}//s);
		next unless (oct($1) == 040000);
		$tree->{$2} = unpack("H*", $3);
	}
	readline($rd);	# Eat extra LF from git cat-file --batch

	$cache->set($hash => $tree)
		if defined($cache);
	return $tree;
}

# Append a new commit on $branch, taking metadata from $commit
# and using $tree as tree.
sub append($$$)
{
	my ($branch, $commit, $tree) = @_;
	my ($pid, $rd, $wr);
	my @args;
	my $hash;

	# If $commit doesn't change this subtree, skip.
	if (defined($branch->{tree}) && $branch->{tree} eq $tree) {
		return;
	}

	$ENV{GIT_AUTHOR_NAME} = $commit->{a_name};
	$ENV{GIT_AUTHOR_EMAIL} = $commit->{a_email};
	$ENV{GIT_AUTHOR_DATE} = $commit->{a_date};
	$ENV{GIT_COMMITTER_NAME} = $commit->{c_name};
	$ENV{GIT_COMMITTER_EMAIL} = $commit->{c_email};
	$ENV{GIT_COMMITTER_DATE} = $commit->{c_date};

	@args = (&GIT, 'commit-tree', '-F', '-');
	if (defined($branch->{head})) {
		push(@args, '-p', $branch->{head});
	}
	push(@args, $tree);
	
	$pid = open2($rd, $wr, @args);
	die("open2(): $!") unless (defined $pid);

	printf($wr "%s", $commit->{log});
	close($wr);

	$hash = <$rd>;
	die("Bad output from write-tree $hash")
		unless($hash =~ &HRE);
	$hash = $1;
	waitpid($pid, 0);

	$branch->{head} = $hash;
	$branch->{tree} = $tree;
}

# Recursively process changes for $commit, with [sub]tree $tree
# and [sub]map $map
sub processtree($$$) {
	my ($commit, $tree, $map) = @_;

	foreach my $dir (keys(%$tree)) {
		if (defined($map->{branches}->{$dir})) {
			append($map->{branches}->{$dir}, $commit,
			    $tree->{$dir});
		}
		if (defined($map->{dirs}->{$dir})) {
			processtree($commit, readtree($tree->{$dir}),
			    $map->{dirs}->{$dir});
		}
	}
}

# Update branch pointers
sub updaterefs($)
{
	my $map = shift;

	foreach my $dir (keys(%{$map->{branches}})) {
		next unless defined($map->{branches}->{$dir}->{head});
		system(&GIT, 'update-ref',
		    'refs/heads/' . $map->{branches}->{$dir}->{name},
		    $map->{branches}->{$dir}->{head});
		debug("%s -> %s\n", $map->{branches}->{$dir}->{name},
		    $map->{branches}->{$dir}->{head});
	}
	foreach my $dir (keys(%{$map->{dirs}})) {
		updaterefs($map->{dirs}->{$dir});
	}
}
