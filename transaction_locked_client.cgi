#!/usr/bin/perl
package main;

use strict;
use warnings;
use f_brokerincludeall;
use CGI;

use BOM::Platform::Runtime;
use BOM::Database::DataMapper::Client;
use BOM::Platform::Plack qw( PrintContentType );

use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('Clients Locked in Transaction');

BOM::Backoffice::Auth0::can_access(['CS']);

Bar('Clients Locked');

my $cgi     = CGI->new;
my @clients = $cgi->param('clients');

foreach my $client_loginid (@clients) {
    try {
        my $client_data_mapper = BOM::Database::DataMapper::Client->new({
            client_loginid => $client_loginid,
        });
        $client_data_mapper->unlock_client_loginid();
        print '<em>Unlocked: ' . $client_loginid . '</em><br>';
    }
    catch {
        print '<h1>ERROR! Could not unlock: ' . $client_loginid . '[' . $_ . ']</h1><br>';
    };
}

my $client_data_mapper = BOM::Database::DataMapper::Client->new({
    broker_code => request()->broker->code,
});

my $clients_list = $client_data_mapper->locked_client_list();

BOM::Platform::Context::template->process('backoffice/transaction_locked_client.html.tt', {locked_client_list => $clients_list})
    || die BOM::Platform::Context::template->error();

code_exit_BO();
