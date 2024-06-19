#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Date::Utility;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Syntax::Keyword::Try;
use Time::Moment;
use YAML::XS qw(LoadFile);
use RedisDB;
use constant TRIGGER_RESYNC_STREAM_NAME => 'dx_resync_request';

BOM::Backoffice::Sysinit::init();

my $cgi   = CGI->new;
my $input = request()->params;
my $staff = BOM::Backoffice::Auth::get_staffname();
my @info_for_output;

my (
    $redis_cfds,          $result,            $script_running, %last_execution_info, $last_execution_date, $staffname,
    $exec_start_datetime, $exec_end_datetime, $accounts,       $orders_resynced,     $next_run_at
);

try {
    my $redis_config = LoadFile('/etc/rmg/redis-cfds.yml');
    $redis_cfds = RedisDB->new(
        host     => $redis_config->{write}{host},
        port     => $redis_config->{write}{port},
        password => $redis_config->{write}{password},
    );
    $result         = $redis_cfds->execute('hgetall', 'dx_resync_last_execution');
    $script_running = $redis_cfds->execute('get',     'dx_resync_running');

    %last_execution_info = @$result;
    $last_execution_date = $last_execution_info{'datetime'} ? Date::Utility->new($last_execution_info{'datetime'})->datetime_ddmmmyy_hhmmss_TZ : '';
    $staffname           = $last_execution_info{'staffname'};
    $exec_start_datetime = $last_execution_info{'exec_start_datetime'};
    $exec_end_datetime   = $last_execution_info{'exec_end_datetime'};
    $accounts            = $last_execution_info{'accounts'};
    $orders_resynced     = $last_execution_info{'orders_resynced'};
    $next_run_at         = $last_execution_info{'dx_resync_next_run_available_at'};

} catch ($e) {
    push @info_for_output, qq~<label style="color: var(--color-red);">Unable to fetch data from the previous execution</label>~;
}

PrintContentType();
BrokerPresentation("Resync Service");
Bar("Trigger DerivX Resync Service");

BOM::Backoffice::Request::template()->process(
    'backoffice/resync_service.html.tt',
    {
        input               => $input,
        refresh_url         => request()->url_for('backoffice/f_resync_service.cgi'),
        last_execution      => $last_execution_date     || 'Unknown',
        staffname           => $staffname               || 'Unknown',
        exec_start_datetime => $exec_start_datetime     || 'Unknown',
        exec_end_datetime   => $exec_end_datetime       || 'Unknown',
        prev_start_datetime => $input->{start_datetime} || Date::Utility->today->minus_time_interval('1d')->db_timestamp,
        prev_end_datetime   => $input->{end_datetime}   || Date::Utility->today->db_timestamp,
        accounts            => defined $accounts        ? "for $accounts accounts" : '',
        orders_resynced     => defined $orders_resynced ? $orders_resynced         : 'Unknown'
    });

push @info_for_output, qq~<label style="color: var(--color-green);">The script is currently running</label><br>~ if $script_running;

push @info_for_output,
    qq~<label>The script will be available for execution again at  ~ . Date::Utility->new($next_run_at)->db_timestamp . qq~</label><br>~
    if ($next_run_at and $next_run_at > Time::Moment->now->epoch);
if ($input->{'resync-button'}) {

    my $dates_ok = 1;

    unless ($input->{start_datetime}) {
        push @info_for_output, qq~<label style="color: var(--color-red);">Please select Start Datetime</label><br>~;
        $dates_ok = 0;
    }

    unless ($input->{end_datetime}) {
        push @info_for_output, qq~<label style="color: var(--color-red);">Please select End Datetime</label><br>~;
        $dates_ok = 0;
    }

    my ($start_datetime, $end_datetime);

    if ($dates_ok) {

        # The date format must be yyyy-mm-ddThh:mm:ss for Date::Utility, adding the seconds at the end
        $start_datetime = Date::Utility->new($input->{start_datetime} . ":00");
        $end_datetime   = Date::Utility->new($input->{end_datetime} . ":00");

        if ($start_datetime->epoch >= $end_datetime->epoch) {
            push @info_for_output, qq~<label style="color: var(--color-red);">End Datetime must be greater than the Start Datetime</label><br>~;
            $dates_ok = 0;
        }
    }

    if ($dates_ok) {

        try {

            $redis_cfds->execute(
                'xadd',
                TRIGGER_RESYNC_STREAM_NAME,
                "MAXLEN", "~", '10000', "*",
                (
                    start_datetime => $start_datetime->epoch,
                    end_datetime   => $end_datetime->epoch,
                    staffname      => $staff
                ));
            push @info_for_output,
                qq~<label style="color: var(--color-green);">Running Resync Service, press refresh to check the status of the execution</label>~;

        } catch ($e) {
            push @info_for_output, qq~<label style="color: var(--color-red);">Something went wrong</label>~;
        }

    }

}

if (@info_for_output) {
    print '<hr>';
    foreach my $line (@info_for_output) {
        print $line;
    }
}

code_exit_BO();
