#!/etc/rmg/bin/perl
package main;

=pod

=head1 DESCRIPTION

This script responsible to check IB affiliate status
and populate this information to mt5 server
(which only accessible by Marketing team)

=cut

use strict;
use warnings;
use f_brokerincludeall;
use Digest::SHA qw(sha256_hex);
use BOM::Platform::Event::Emitter;
use BOM::MyAffiliates;
use Data::Dumper;

use constant SALT_FOR_CSRF_TOKEN => 'emDWVx1SH68JE5N1ba9IGz5fb';

BOM::Backoffice::Sysinit::init();

my $input = request()->params;

my $clerk = BOM::Backoffice::Auth0::get_staffname() // '';

code_exit_BO('ACCESS DENIED: This page only for Marketing Team') unless BOM::Backoffice::Auth0::has_authorisation(['Marketing']);

PrintContentType();

my $loginid = $input->{loginid} // '';

BrokerPresentation("AFFILIATE IB STATUS MANAGING");

my $client = BOM::User::Client->new({loginid => $input->{loginid}});

my ($affiliate_id, $mt5_login, $action, $action_result);
if (request()->http_method eq 'POST') {
    code_exit_BO(_get_display_error_message('Invalid CSRF Token')) if $input->{_csrf} ne _get_csrf_token();

    $affiliate_id = $input->{affiliate_id};
    $mt5_login    = $input->{mt5_login};
    $action       = $input->{action};
    if ($action eq 'sync_to_mt5') {
        $action_result = BOM::Platform::Event::Emitter::emit(
            affiliate_sync_initiated => {
                affiliate_id => $affiliate_id,
                mt5_login    => $mt5_login,
                email        => $input->{email},
            },
        ) ? 'success' : 'fail';
    } else {
        code_exit_BO(_get_display_error_message('Invalid Action'));
    }
} else {
    my $my_affiliates = BOM::MyAffiliates->new();

    code_exit_BO(_get_display_error_message('Client isn\'t an affiliate')) unless $client->myaffiliates_token;

    $affiliate_id = $my_affiliates->get_affiliate_id_from_token($client->myaffiliates_token);
    my $affiliate = $my_affiliates->get_user($affiliate_id);

    my @user_variables =
        $affiliate->{USER_VARIABLES} && ref $affiliate->{USER_VARIABLES}{VARIABLE} eq 'ARRAY'
        ? @{$affiliate->{USER_VARIABLES}{VARIABLE}}
        : ();

    ($mt5_login) = map { $_->{VALUE} } grep { $_->{NAME} eq 'mt5_account' } @user_variables;
}

BOM::Backoffice::Request::template()->process(
    'backoffice/ib_affiliate.html.tt',
    {
        mt5_login     => $mt5_login,
        clerk         => encode_entities($clerk),
        affiliate_id  => $affiliate_id,
        loginid       => $loginid,
        csrf          => _get_csrf_token(),
        action        => $action,
        action_result => $action_result,
        email         => $clerk . '@binary.com'
    });

code_exit_BO();

# IT'D BETTER TO MAKE GENERAL SOLUTION FOR CSRF, BUT FOR NOW BETTER THAN NOTHING
sub _get_csrf_token {
    my $auth_token = request()->cookies->{auth_token};

    die "Can't find auth token" unless $auth_token;

    return sha256_hex(SALT_FOR_CSRF_TOKEN . $auth_token);
}
