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
use HTTP::Tiny;
use Data::Dump 'pp';
use Date::Utility;

use constant DEALS_HASH_RESULTS_NAME   => 'ctrader::deals::resync::results';
use constant TRADERS_HASH_RESULTS_NAME => 'ctrader::traders::resync::results';
use constant DEALS_SCRIPT_LOCK         => 'ctrader::deals::resync::lock';
use constant TRADERS_SCRIPT_LOCK       => 'ctrader::traders::resync::lock';

BOM::Backoffice::Sysinit::init();

my $cgi   = CGI->new;
my $input = request()->params;
my $staff = BOM::Backoffice::Auth::get_staffname();
my @info_for_output;

my (
    $redis_cfds,        $deals_resync_result, $traders_resync_result, $deals_script_running, $traders_script_running, $exec_start_datetime,
    $exec_end_datetime, $nb_deals,            $nb_traders,            $last_run_deals,       $last_run_traders,       $start_date_deals,
    $end_date_deals,    $start_date_traders,  $end_date_traders,      $staffname_deals,      $staffname_traders,
);

try {
    my $redis_config = LoadFile('/etc/rmg/redis-ctrader-bridge.yml');

    $redis_cfds = RedisDB->new(
        host     => $redis_config->{write}{host},
        port     => $redis_config->{write}{port},
        password => $redis_config->{write}{password},
    );
    $deals_resync_result    = $redis_cfds->execute('hgetall', DEALS_HASH_RESULTS_NAME);
    $traders_resync_result  = $redis_cfds->execute('hgetall', TRADERS_HASH_RESULTS_NAME);
    $deals_script_running   = $redis_cfds->execute('get',     DEALS_SCRIPT_LOCK);
    $traders_script_running = $redis_cfds->execute('get',     TRADERS_SCRIPT_LOCK);

    extract_values($deals_resync_result,   \$nb_deals,   \$last_run_deals,   \$start_date_deals,   \$end_date_deals,   \$staffname_deals);
    extract_values($traders_resync_result, \$nb_traders, \$last_run_traders, \$start_date_traders, \$end_date_traders, \$staffname_traders);

} catch ($e) {
    push @info_for_output, qq~<label style="color: var(--color-red);">Unable to fetch data from the previous execution</label>~;
}

PrintContentType();
BrokerPresentation("cTrader Resync Service");
Bar("Trigger cTrader Resync Service");

BOM::Backoffice::Request::template()->process(
    'backoffice/ctrader_resync_service.html.tt',
    {
        input                  => $input,
        refresh_url            => request()->url_for('backoffice/f_ctrader_resync_service.cgi'),
        last_run_deals         => $last_run_deals          || 'Unknown',
        last_run_traders       => $last_run_traders        || 'Unknown',
        start_date_deals       => $start_date_deals        || 'Unknown',
        end_date_deals         => $end_date_deals          || 'Unknown',
        start_date_traders     => $start_date_traders      || 'Unknown',
        end_date_traders       => $end_date_traders        || 'Unknown',
        staffname_deals        => $staffname_deals         || 'Unknown',
        staffname_traders      => $staffname_traders       || 'Unknown',
        nb_deals               => $nb_deals                || '0',
        nb_traders             => $nb_traders              || '0',
        exec_start_datetime    => $exec_start_datetime     || 'Unknown',
        exec_end_datetime      => $exec_end_datetime       || 'Unknown',
        prev_start_datetime    => $input->{start_datetime} || Date::Utility->today->minus_time_interval('1d')->db_timestamp,
        prev_end_datetime      => $input->{end_datetime}   || Date::Utility->today->db_timestamp,
        prev_selected_deals    => defined $input->{service_type} && $input->{service_type} eq 'deals'   ? 'selected' : '',
        prev_selected_traders  => defined $input->{service_type} && $input->{service_type} eq 'traders' ? 'selected' : '',
        deals_script_running   => $deals_script_running   ? 'Deals resyncing currently running'   : '',
        traders_script_running => $traders_script_running ? 'Traders resyncing currently running' : '',
    });

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
            my $api_port = $input->{service_type} eq 'traders' ? '3004' : '3005';

            $redis_cfds->execute(
                'hset',         'ctrader::' . $input->{service_type} . '::resync::results',
                'staffName',    $staff, 'startDate', $start_datetime->datetime_iso8601,
                'endDate',      $end_datetime->datetime_iso8601,
                'lastExecTime', Date::Utility->new->datetime_iso8601,
                'nbItems',      0
            );

            my $payload = {
                payload => {
                    serviceType => $input->{service_type},
                    startDate   => $start_datetime->datetime_iso8601,
                    endDate     => $end_datetime->datetime_iso8601
                }};

            my $http = HTTP::Tiny->new(timeout => 10);

            my $result = $http->post(
                'http://localhost:' . $api_port . '/resync',
                {
                    headers => {'Content-Type' => 'application/json'},
                    content => encode_json($payload)});

            if (!$result->{success}) {
                push @info_for_output, qq~<label style="color: var(--color-red);">Something went wrong : $result->{content}</label>~;
            } else {
                $redis_cfds->execute('hset', 'ctrader::' . $input->{service_type} . '::resync::results', 'nbItems', $result->{content},);

                push @info_for_output,
                    qq~<label style="color: var(--color-green);">Running Resync Service, press refresh to check the status of the execution</label>~;
            }
        } catch ($e) {
            push @info_for_output, qq~<label style="color: var(--color-red);">Something went wrong : $e</label>~;
        }
    }
}

sub extract_values {
    my ($result_ref, $nb_items_ref, $last_exec_time_ref, $start_date_ref, $end_date_ref, $staff_name_ref) = @_;

    foreach my $index (0 .. $#$result_ref) {
        my $key   = $result_ref->[$index];
        my $value = $result_ref->[$index + 1];

        if ($key eq "nbItems") {
            $$nb_items_ref = $value;
        } elsif ($key eq "lastExecTime") {
            $$last_exec_time_ref = $value;
        } elsif ($key eq "startDate") {
            $$start_date_ref = $value;
        } elsif ($key eq "endDate") {
            $$end_date_ref = $value;
        } elsif ($key eq "staffName") {
            $$staff_name_ref = $value;
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
