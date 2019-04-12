#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use BOM::Config;
use BOM::Backoffice::Config qw/get_tmp_path_or_die/;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::User::Client::PaymentAgent;
BOM::Backoffice::Sysinit::init();
PrintContentType();

my $broker            = request()->broker_code;
my $result            = {};
my $action            = request()->param('submit') // '';
my $selected_country  = request()->param("country") // '';
my $selected_currency = request()->param("currency") // 'USD';
if ($action and $action eq 'submit') {
    $result = BOM::User::Client::PaymentAgent->get_payment_agents(
        country_code => $selected_country,
        broker_code  => $broker,
        currency     => $selected_currency,
    );
}

BrokerPresentation("Authorized Payment Agent List");
Bar("Authorized Payment Agent List");

BOM::Backoffice::Request::template()->process(
    'backoffice/payment_agent_list.html.tt',
    {
        submit_form_url   => request()->url_for("backoffice/f_payment_agent_list.cgi?broker=$broker"),
        countries_list    => Brands->new(name => 'Binary')->countries_instance->countries->{_country_codes},
        selected_country  => $selected_country,
        records           => $result,
        currency_options  => request()->available_currencies,
        selected_currency => $selected_currency
    }) || die BOM::Backoffice::Request::template()->error;

code_exit_BO();
