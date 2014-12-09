#!/usr/bin/perl
package main;

use BOM::Platform::MyAffiliates::GenerateRegistrationDaily;
use BOM::Utility::Log4perl;
use BOM::Platform::Runtime;
use BOM::Platform::Email qw(send_email);
use include_common_modules;

run() unless caller;

sub run {
    use Getopt::Long;
    BOM::Utility::Log4perl::init_log4perl_console;
    su_nobody();
    system_initialize();

    my $to;
    GetOptions('to=s' => \$to);

    my $result = BOM::Platform::MyAffiliates::GenerateRegistrationDaily->new->run;
    send_email({
        from    => BOM::Platform::Runtime->instance->app_config->system->email,
        to      => BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email,
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
