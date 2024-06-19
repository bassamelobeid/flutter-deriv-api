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

# TODO - instantiate partner hub module
my $partner_hub = undef;

# for testing purposesA
package PartnerHub {

    sub new {
        my $class = shift;
        my $self  = {};
        bless $self, $class;
        return $self;
    }

    sub get_users {
        my ($self, %args) = @_;
        my $loginid = $args{VARIABLE_VALUE};
        return {
            USER => {
                loginid   => $loginid,
                USERNAME  => 'TEST_user',
                EMAIL     => 'testemail@email.com',
                ID        => '123456',
                STATUS    => 'test status',
                JOIN_DATE => '2020-01-01',
                LANGUAGE  => 'English',
                COUNTRY   => 'AE',
                BALANCE   => '1000',
                CURRENCY  => 'USD',
            }};
    }
};

$partner_hub = PartnerHub->new;

my @partners;
for my $sibling ($client->user->clients) {
    my $res = $partner_hub->get_users(
        VARIABLE_NAME  => 'affiliates_client_loginid',
        VARIABLE_VALUE => $sibling->loginid
    );
    my @result =
          ref $res->{USER} eq 'ARRAY' ? @{$res->{USER}}
        : $res->{USER}                ? ($res->{USER})
        :                               ();
    push @partners, @result;
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
