#!/etc/rmg/bin/perl
package main;

use Brands;
use BOM::MyAffiliates::GenerateRegistrationDaily;
use BOM::Platform::Email qw(send_email);

local $SIG{ALRM} = sub { die "alarm\n" };
alarm 1800;

run() unless caller;

sub run {
    use Getopt::Long;
    su_nobody();

    my $to;
    GetOptions('to=s' => \$to);

    my $result = BOM::MyAffiliates::GenerateRegistrationDaily->new->run;
    my $brand = Brands->new();
    send_email({
        from    => $brand->emails('system'),
        to      => $brand->emails('affiliates'),
        subject => 'CRON registrations: Report for ' . $result->{start_time}->datetime_yyyymmdd_hhmmss_TZ,
        message => $result->{report},
    });
}

sub su_nobody {
    use English '-no_match_vars';
    if ($EFFECTIVE_USER_ID == 0) {
        my (undef, undef, $nogroup_gid, undef) = getgrnam('nogroup');
        $EFFECTIVE_GROUP_ID = $nogroup_gid;
        my (undef, undef, $nobody_uid, undef, undef, undef, undef, undef, undef, undef) = getpwnam('nobody');
        $EFFECTIVE_USER_ID = $nobody_uid;
    }
}
