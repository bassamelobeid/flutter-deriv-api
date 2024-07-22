#!/etc/rmg/bin/perl

=head1 NAME

Compute Virtual Status

=head1 DESCRIPTION

A Backoffice script to return the virtual statuses of a client in HTML format.

=cut

package main;

use strict;
use warnings;

use lib qw(/home/git/regentmarkets/bom-backoffice);

use BOM::Backoffice::Sysinit ();
use Log::Any                 qw($log);
use Time::HiRes;
use BOM::Backoffice::Request;
use BOM::User::Client;
use BOM::Backoffice::VirtualStatus;
use DataDog::DogStatsd::Helper qw(stats_timing);
BOM::Backoffice::Sysinit::init();

my $start_time = Time::HiRes::time();

my $loginid = request()->param('loginID');

die 'loginID is required' unless $loginid;

my $client = BOM::User::Client->get_client_instance($loginid);

my %virtual_statuses = BOM::Backoffice::VirtualStatus::get($client);

my $template_param = {
    client_statuses_readonly => \%virtual_statuses,
};

my $time_consumed = Time::HiRes::time() - $start_time;
stats_timing('backoffice.compute_virtual_status', $time_consumed);

print BOM::Backoffice::Request::template()->process('backoffice/account/read_only_statuses.html.tt', $template_param, undef, {binmode => ':utf8'})
    || die BOM::Backoffice::Request::template()->error(), "\n";
