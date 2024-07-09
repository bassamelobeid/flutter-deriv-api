#!/etc/rmg/bin/perl

=head1 NAME

Proof of Ownership Details

=head1 DESCRIPTION

A Backoffice script to return the proof of ownership details of a client in HTML.

=cut

package main;

use strict;
use warnings;

use lib qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeXS;

use BOM::Backoffice::Sysinit ();
use Log::Any                 qw($log);
use Time::HiRes;
use BOM::User::Client;
use BOM::Backoffice::Request;
use BOM::Config::Runtime;
use DataDog::DogStatsd::Helper qw(stats_timing);
BOM::Backoffice::Sysinit::init();

my $start_time = Time::HiRes::time();
my $loginid    = request()->param('loginID');

die 'loginID is required' unless $loginid;

$log->infof("%s: Computing proof of ownership details for client %s", request()->id, $loginid);

my $client = BOM::User::Client->get_client_instance($loginid, 'backoffice_replica');

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->check_for_update();
my $payment_method_config = $app_config->payments->payment_methods_with_poo;

my $doughflow_methods = $client->db->dbic->run(
    fixup => sub {
        $_->selectall_arrayref('SELECT * FROM payment.doughflow_deposit_methods_without_poo(?, ?)',
            undef, $client->binary_user_id, $payment_method_config);
    });
my $proof_of_ownership_list = $client->proof_of_ownership->list();

my $template_param = {
    doughflow_methods       => $doughflow_methods,
    proof_of_ownership_list => $proof_of_ownership_list,
};

my $time_consumed = Time::HiRes::time() - $start_time;
stats_timing('backoffice.client_poo_details', $time_consumed);

$log->infof("%s: Computed proof of ownership details", request()->id);

print BOM::Backoffice::Request::template()->process('backoffice/account/proof_of_ownership.html.tt', $template_param, undef, {binmode => ':utf8'})
    || die BOM::Backoffice::Request::template()->error(), "\n";

