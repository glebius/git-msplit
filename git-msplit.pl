#!/usr/local/bin/perl -wT

use strict;

use Getopt::Std;
use IPC::Open2;
use Dumpvalue;

$ENV{PATH} = "";

use constant GIT	=> '/usr/local/bin/git';
use constant HRE	=> '^([0-9a-f]{40})$';
use constant TRE	=> '^([0-7]{5,6}) (.+?)\0(.{20})';
use constant ARE	=> '^(.*) <([^>]+)> ([0-9]+) \+0000$';

sub debug;
sub readmap();
sub readallcommits();
sub readtree($);
sub processbranch($$$);
sub processtree($$$);

my %opts;
getopts("dm:r:", \%opts);
die("Usage: $0 -m map-file [-r revision] [-d]\n")
	unless defined($opts{m});
$opts{r} = "HEAD" unless defined($opts{r});

my %map;	# map of what to split
my @allcommits;	# history to run through

# Open the main workhorse to read data
my ($pid, $rd, $wr);
$pid = open2($rd, $wr, &GIT, 'cat-file', '--batch');
die("open2(): $!") unless (defined $pid);

readmap();
readallcommits();

$ENV{TZ} = "";

my $n = 0;
foreach my $hash (@allcommits) {
	my (@header, $text);
	my $commit;
	my $tree;

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

	$tree = readtree($commit->{tree});

	processtree($commit, $tree, \%map);
	printf("%d/%d\r", $n++, $#allcommits);
}
waitpid($pid, 0);
return;

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
	my ($pid, $rd, $wr);
	my $commits = 0;

	$pid = open2($rd, $wr, &GIT, 'rev-list', '--reverse', $opts{r});
	die("open2(): $!") unless (defined $pid);

	while (<$rd>) {
		die("Bad data in $_")
			unless ($_ =~ &HRE);
		push(@allcommits, $1);
	}
	waitpid($pid, 0);
	debug("%d commits to process\n", $#allcommits);
}

sub readtree($) {
	my $hash = shift;
	my (@header, $text);
	my $tree;

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
	return $tree;
}

sub processbranch($$$)
{
	my ($branch, $commit, $tree) = @_;
	my ($pid, $rd, $wr);
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

	system(&GIT, 'update-ref', 'refs/heads/' . $branch->{name}, $hash);
}

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
