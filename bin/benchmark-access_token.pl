#!/etc/rmg/bin/perl

use strict;
use warnings;
use BOM::Database::Model::OAuth;
use Time::HiRes ();

my ($token, $req, $fork) = @ARGV;

$req //= 1_000;
$fork //= 3;

sub doit {
    my $m=BOM::Database::Model::OAuth->new;
    my $stmp = Time::HiRes::time;
    while ($req--) {
	$m->get_loginid_by_access_token($token);
    }
    printf "Child $$: %.3f sec\n", Time::HiRes::time - $stmp;
}

my (@pids, $pid);

for (1..$fork) {
    select undef, undef, undef, 0.1 until (defined ($pid=fork));
    if ($pid) {			# parent
	push @pids, $pid;
    } else {			# child
	@pids=();
	doit;
	exit 0;
    }
}

my $stmp = Time::HiRes::time;
waitpid $_, 0 for @pids;
printf "Parent: %.3f sec\n", Time::HiRes::time - $stmp;
