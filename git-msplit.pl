#!/usr/local/bin/perl -wT

use strict;

use Getopt::Std;
use IPC::Open2;
use Dumpvalue;

$ENV{PATH} = "";

use constant GIT	=> '/usr/local/bin/git';
use constant HRE	=> '^([0-9a-f]{40})$';
use constant TRE	=> '^[0-7]{6} (tree|blob) ([0-9a-f]{40})\t(.+)$';
use constant ARE	=> '^(.*) <([^>]+)> ([0-9]+) \+0000$';

my %opts;
getopts("dm:r:", \%opts);
die("Usage: $0 -m map-file [-r revision] [-d]\n")
	unless defined($opts{m});
$opts{r} = "HEAD" unless defined($opts{r});

my (%map, @allcommits);

sub debug
{
	printf(@_) if defined($opts{d});
}

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
				# XXXGL: this doesn't match # what git
				# imposes on branch name.
				die("Bad branch name $line[1]")
					unless($line[1] =~ /^([\w\/.-]+)$/);
				$line[1] = $1;
				$dir->{branches}->{$dirs[$d]} = {
					name => $line[1],
					ref => undef,
					head => undef,
					tree => undef,
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

sub readallcommits() {
	local (*WR, *RD);
	my $pid;
	my $commits = 0;

	$pid = open2(\*RD, \*WR, &GIT, 'rev-list', '--reverse', $opts{r});
	die("open2(): $!") unless (defined $pid);

	while (<RD>) {
		die("Bad data in $_")
			unless ($_ =~ &HRE);
		push(@allcommits, $1);
	}
	waitpid($pid, 0);
	debug("%d commits to process\n", $#allcommits);
}

sub readcommit($) {
	my $hash = shift;
	my $commit;
	local (*WR, *RD);
	my $pid;

	$pid = open2(\*RD, \*WR, &GIT, 'cat-file', '-p', $hash);
	die("open2(): $!") unless (defined $pid);

	while (<RD>) {
		my ($key, $val);

		chomp;
		($key, $val) = split(/ /, $_, 2);
		last unless defined($key);

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
	while (<RD>) {
		$commit->{log} .= $_;
	}
	waitpid($pid, 0);

	return $commit;
#	printf("%s\n", $hash);
#	foreach my $key (keys(%$commit)) {
#		next if ($key eq "log");
#		printf("%s %s\n", $key, $commit->{$key});
#	}
#	printf("%s\n", $commit->{log});
}

sub readtree($) {
	my $hash = shift;
	my $tree;
	local (*WR, *RD);
	my $pid;

	$pid = open2(\*RD, \*WR, &GIT, 'cat-file', '-p', $hash);
	die("open2(): $!") unless (defined $pid);

	while (<RD>) {
		die("Bad data in $_")
			unless($_ =~ &TRE);
		$tree->{$3} = $2
			if ($1 eq "tree");
	}
	waitpid($pid, 0);

	return $tree;
}

sub processbranch($$$)
{
	my ($branch, $commit, $tree) = @_;
	local (*WR, *RD);
	my $pid;
	my @args;
	my $hash;

	if (defined($branch->{tree}) && $branch->{tree} eq $tree) {
		return;
	}

	$ENV{GIT_AUTHOR_NAME} = $commit->{a_name};
	$ENV{GIT_AUTHOR_EMAIL} = $commit->{a_email};
	$ENV{GIT_AUTHOR_DATE} = $commit->{a_date};
	$ENV{GIT_COMMITTER_NAME} = $commit->{c_name};
	$ENV{GIT_COMMITTER_EMAIL} = $commit->{c_email};
	$ENV{GIT_COMMITTER_DATE} = $commit->{c_date};

	@args = ( \*RD, \*WR, &GIT, 'commit-tree', '-F', '-');
	if (defined($branch->{head})) {
		push(@args, '-p', $branch->{head});
	}
	push(@args, $tree);
	
	$pid = open2(@args);
	die("open2(): $!") unless (defined $pid);

	printf(WR "%s", $commit->{log});
	close(WR);

	$hash = <RD>;
	die("Bad output from write-tree $hash")
		unless($hash =~ &HRE);
	$hash = $1;
	waitpid($pid, 0);

	$branch->{head} = $hash;
	$branch->{tree} = $tree;

	system(&GIT, 'update-ref', 'refs/heads/' . $branch->{name}, $hash);
}

sub processtree($$$);
sub processtree($$$) {
	my ($commit, $tree, $map) = @_;

	foreach my $dir (keys(%$tree)) {
		if (defined($map->{branches}->{$dir})) {
			processbranch($map->{branches}->{$dir}, $commit,
			    $tree->{$dir});
		}
		if (defined($map->{dirs}->{$dir})) {
			processtree($commit, readtree($tree->{$dir}),
			    $map->{dirs}->{$dir});
		}
	}
}

#
# Begin
#

readmap();
readallcommits();

$ENV{TZ} = "";

my $n = 0;

foreach my $hash (@allcommits) {
	my $commit;
	my $tree;

	$commit = readcommit($hash);
	$tree = readtree($commit->{tree});

	processtree($commit, $tree, \%map);
	printf("%d/%d\r", $n++, $#allcommits);
}
