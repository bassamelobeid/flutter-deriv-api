#!/etc/rmg/bin/perl
package main;

=pod

=head1 DESCRIPTION

This script retrieves partner details by client loginid and displays them as a table.
It will also indicate whether or not the client is not a partner.

=cut

use strict;
use warnings;

use List::Util qw(first);

use BOM::User::Client;
use BOM::Config::Runtime;
use BOM::DynamicWorks::DataBase::CommissionDBModel;
use BOM::MyAffiliates::DynamicWorks::Integration;

my $commission_db = BOM::DynamicWorks::DataBase::CommissionDBModel->new;
my $integration   = BOM::MyAffiliates::DynamicWorks::Integration->new;

BOM::Backoffice::Sysinit::init();

BOM::Config::Runtime->instance->app_config->check_for_update();

code_exit_BO(qq[This page is not accessible as partners.enable_dynamic_works is disabled])
    unless BOM::Config::Runtime->instance->app_config->partners->enable_dynamic_works;

PrintContentType();
BrokerPresentation("PARTNER DETAILS");

my $input           = request()->params;
my $loginid         = $input->{loginid} // '';
my $encoded_loginid = encode_entities($loginid);

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginid, db_operation => 'backoffice_replica'}) };

code_exit_BO(qq[ERROR : Wrong loginID $encoded_loginid]) unless $client;

my @partners;
my $binary_user = $client->user;
$log->errorf($binary_user->id);

my $affiliate_users_hashref = $commission_db->get_affiliates({binary_user_id => $binary_user->id, provider => 'dynamicworks'});

code_exit_BO(qq[Could not load affiliate details]) unless $affiliate_users_hashref->{success};

code_exit_BO(qq[Client is not an affiliate]) unless scalar @{$affiliate_users_hashref->{affiliates}};

my $affiliate_users = $affiliate_users_hashref->{affiliates};

for my $affiliate_user (@$affiliate_users) {
    my $client = BOM::User::Client::get_instance({loginid => $affiliate_user->{payment_loginid}, db_operation => 'backoffice_replica'});
    my $sidcs  = $integration->get_sidcs($affiliate_user->{external_affiliate_id});
    push @partners, {
        loginid      => $client->{loginid},
        email        => $binary_user->{email} // $client->{email},
        partner_id   => $affiliate_user->{external_affiliate_id},
        joining_date => $affiliate_user->{created_at},
        country      => Locale::Country::Extra->new()->country_from_code($client->residence),
        currency     => $client->currency,
        plans        => $sidcs,

    };
}

code_exit_BO(qq[Client isn\'t a partner]) unless @partners;

for my $partner (@partners) {
    Bar(" PARTNER DETAILS - $partner->{loginid} ");

    my $client_details_link = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $partner->{loginid}});

    BOM::Backoffice::Request::template()->process(
        'backoffice/client_partner_details.html.tt',
        {
            partner             => $partner,
            client_details_link => $client_details_link,
        });
}

code_exit_BO();
