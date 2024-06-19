#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use List::Util qw(max first any);
use Syntax::Keyword::Try;
use Text::Trim qw(trim);
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Database::ClientDB;
use BOM::User::Client;
use BOM::Rules::Engine;
use LandingCompany::Registry;
use BOM::Backoffice::Auth;
use BOM::Platform::Event::Emitter;

BOM::Backoffice::Sysinit::init();
PrintContentType();

use constant PA_PAGE_LIMIT => 50;

my %params     = request()->params->%*;
my $app_config = BOM::Config::Runtime->instance->app_config;
my %output     = (can_edit => BOM::Backoffice::Auth::has_authorisation(['Compliance']));

if (request()->http_method eq 'POST') {

    if ($output{can_edit}) {

        if (any { $params{$_} } qw(save_remark approve reject suspend)) {
            if (my $field = first { $_ =~ /^remark_edit_/ } keys %params) {
                my ($loginid) = $field =~ /^remark_edit_(.+)$/;

                try {
                    my $client = BOM::User::Client->new({loginid => $loginid})
                        or die "$loginid is not a valid loginid\n";

                    my $pa = $client->get_payment_agent or die "$loginid is not a Payment Agent and has not applied.\n";
                    $pa->status_comment(trim($params{$field}));
                    $pa->save;
                    push $output{messages}->@*, "Updated remark for $loginid.\n";

                } catch ($e) {
                    push $output{errors}->@*, $e;
                }
            }
        }

        if (any { $params{$_} } qw(approve reject suspend)) {
            my $loginids = $params{process_loginid} or die "No clients selected\n";

            for my $loginid (sort (ref $loginids ? @$loginids : $loginids)) {

                try {
                    my $client = BOM::User::Client->new({loginid => $loginid})
                        or die "$loginid is not a valid loginid\n";

                    my $pa = $client->get_payment_agent or die "$loginid has not applied to be a Payment Agent.\n";

                    if ($params{approve}) {
                        die "$loginid PA status is already authorized.\n" if $pa->status eq 'authorized';

                        my $rule_engine = BOM::Rules::Engine->new(client => $client);
                        my $failures    = $rule_engine->apply_rules(
                            ['paymentagent.client_status_can_apply_for_pa', 'paymentagent.client_has_mininum_deposit'],
                            loginid             => $client->loginid,
                            rule_engine_context => {stop_on_failure => 0},
                        )->failed_rules;

                        if (@$failures) {
                            for my $error (@$failures) {
                                if ($error->{error_code} eq 'PaymentAgentClientStatusNotEligible') {
                                    push $output{errors}->@*, "$loginid has an invalid client status.";
                                }
                                if ($error->{error_code} eq 'PaymentAgentInsufficientDeposit') {
                                    push $output{errors}->@*, "$loginid deposit is below minimum.";
                                }
                            }
                            next;
                        }

                        $pa->status('authorized');
                        $pa->newly_authorized(1);    # set the 'newly_authorized' flag
                        $pa->save;
                        push $output{messages}->@*, "$loginid has been authorized.\n";

                        my ($is_pa_approved_before) = $client->db->dbic->run(
                            fixup => sub {
                                $_->selectrow_array('SELECT * FROM betonmarkets.paymentagent_approved_before_check(?)', undef, $loginid);
                            });

                        if (!$is_pa_approved_before) {
                            my $brand   = request()->brand;
                            my $lang    = $client->user->preferred_language // 'EN';
                            my $tnc_url = $brand->tnc_approval_url({language => uc($lang)});

                            BOM::Platform::Event::Emitter::emit(
                                pa_first_time_approved => {
                                    loginid    => $loginid,
                                    properties => {
                                        first_name    => $client->first_name,
                                        contact_email => $brand->emails('pa_business'),
                                        tnc_url       => $tnc_url,
                                    }});
                        }

                    }

                    if ($params{reject}) {
                        die "$loginid is already rejected.\n" if $pa->status eq 'rejected';
                        $pa->status('rejected');
                        $pa->save;
                        push $output{messages}->@*, "$loginid has been rejected.\n";
                    }

                    if ($params{suspend}) {
                        die "$loginid is already suspended.\n" if $pa->status eq 'suspended';
                        $pa->status('suspended');
                        $pa->save;
                        push $output{messages}->@*, "$loginid has been suspended.\n";
                    }
                } catch ($e) {
                    push $output{errors}->@*, $e;
                }
            }
        }
    }

    $params{deposit_reqs}        = $app_config->payment_agents->initial_deposit_per_country;
    $params{reversible_limit}    = $app_config->payments->reversible_balance_limits->pa_deposit / 100;
    $params{reversible_lookback} = $app_config->payments->reversible_deposits_lookback;
    $params{client_statuses}     = [qw(cashier_locked shared_payment_method no_withdrawal_or_trading withdrawal_locked unwelcome duplicate_account)];

    $params{start} //= 0;
    $params{limit} = PA_PAGE_LIMIT + 1;
    delete $params{$_} for grep { !length($params{$_}) } qw(status currency country loginid risk_level eligible application_date);

    my $db = BOM::Database::ClientDB->new({
            broker_code => request()->broker_code,
            operation   => 'backoffice_replica'
        })->db->dbic;

    $output{list} = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM betonmarkets.payment_agent_list(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                {Slice => {}},
                @params{
                    qw(country currency status risk_level loginid eligible reversible_limit reversible_lookback client_statuses deposit_reqs limit start application_date)
                },
            );
        });

    $output{prev} = $params{start} > 0                ? max($params{start} - PA_PAGE_LIMIT, 0) : undef;
    $output{next} = $output{list}->@* > PA_PAGE_LIMIT ? $params{start} + PA_PAGE_LIMIT         : undef;
    splice($output{list}->@*, PA_PAGE_LIMIT);
}

my @lcs       = grep { $_->{allows_payment_agents} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
my %countries = request()->brand->countries_instance->countries_list->%*;

for my $country (keys %countries) {
    next unless any { $_->{short} eq $countries{$country}->{financial_company} or $_->{short} eq $countries{$country}->{gaming_company} } @lcs;
    $output{countries}->{$country} = $countries{$country}->{name};
}

$output{currencies} = request()->available_currencies;

BrokerPresentation('Payment Agent List');

BOM::Backoffice::Request::template()->process('backoffice/payment_agent_list.html.tt', {%output, %params, page_limit => PA_PAGE_LIMIT})
    || die BOM::Backoffice::Request::template()->error;

code_exit_BO();
