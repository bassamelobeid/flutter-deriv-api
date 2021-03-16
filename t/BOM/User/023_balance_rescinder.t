use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::User::Script::BalanceRescinder;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw(top_up);
use BOM::Test::Email;

my $fake_rates = {
    BTC  => 0.0000001,
    LTC  => 0.000021,
    ETH  => 0.0000003,
    EURS => 0.9
};

my $clients = [{
        disabled => 1,
        currency => 'USD',
        balance  => 1,
        rescind  => 1,
    },
    {
        disabled => 0,       # not disabled!
        currency => 'USD',
        balance  => 1,
        rescind  => 0,
    },
    {
        disabled => 1,
        currency => 'BTC',
        balance  => 2.1,     # too much btc to rescind
        rescind  => 0,
    },
    {
        disabled => 1,
        currency => 'BTC',
        balance  => 0.00000009,
        rescind  => 1,
    },
    {
        disabled => 1,
        currency => 'EURS',
        balance  => 1,        # stable coin so compute it like fiat 1:1
        rescind  => 1,
    },
    {
        disabled => 1,
        currency => 'EURS',
        balance  => 0.1,
        rescind  => 1,
    }];

my $mock = Test::MockModule->new('BOM::User::Script::BalanceRescinder');

$mock->mock(
    'convert_currency',
    sub {
        my ($amount, $currency) = @_;

        return $amount * ($fake_rates->{$currency} // BOM::User::Script::BalanceRescinder::FIAT_BALANCE_LIMIT);
    });

for my $broker_code (qw/CR MX MLT MF DW/) {
    subtest "Testing $broker_code" => sub {
        my $rescinder = BOM::User::Script::BalanceRescinder->new(broker_code => $broker_code);
        isa_ok($rescinder, 'BOM::User::Script::BalanceRescinder');
        is($rescinder->broker_code, $broker_code, 'Correct broker code');

        my $currencies = $rescinder->currencies;

        for my $curr (keys $currencies->%*) {
            my $type   = $rescinder->landing_company->legal_allowed_currencies->{$curr}->{type};
            my $stable = $rescinder->landing_company->legal_allowed_currencies->{$curr}->{stable};

            my $expected_value = ($type eq 'fiat' || $stable) ? 1 : ($fake_rates->{$curr} // 1);
            is $currencies->{$curr}, $expected_value, "We got the expected value for $curr";
        }

        # Create the accounts
        my $expected_to_rescind = [];

        for my $cli_settings ($clients->@*) {
            next unless grep { $_ eq $cli_settings->{currency} } keys $rescinder->landing_company->legal_allowed_currencies->%*;
            my $cli = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => $broker_code,
            });
            $cli->set_default_account($cli_settings->{currency});
            $cli->status->set('disabled', 'test', 'test') if $cli_settings->{disabled};
            top_up($cli, $cli_settings->{currency}, $cli_settings->{balance}, 'test_account');
            ok $cli->default_account->balance - $cli_settings->{balance} == 0, 'Expected balance after top up';
            push $expected_to_rescind->@*, $cli->loginid if $cli_settings->{rescind};
        }

        # we are asking for disabled accounts from 30 days in the past, this won't hit any recently created account
        my $accounts_to_rescind = [grep { $_ =~ /^$broker_code/ } keys $rescinder->accounts(30, $currencies)->%*];
        cmp_deeply $accounts_to_rescind, [], 'None of the accounts were disabled for more than 30 days';

        # we will fetch disabled accounts from 1 day in the future (-1) so all the accounts are within range
        $accounts_to_rescind = [grep { $_ =~ /^$broker_code/ } keys $rescinder->accounts(-1, $currencies)->%*];
        cmp_deeply $accounts_to_rescind, bag($expected_to_rescind->@*), 'We got the expected accounts to rescind';

        my $expected_summary = {};

        for my $rescind (values $rescinder->accounts(-1, $currencies)->%*) {
            $expected_summary->{$rescind->{client_loginid}} = {
                currency => $rescind->{currency_code},
                amount   => $rescind->{balance},
            };

            ok $rescinder->rescind($rescind->{client_loginid}, $rescind->{currency_code}, $rescind->{balance}), 'Balance successfully rescinded';

            my $cli = BOM::User::Client->new({loginid => $rescind->{client_loginid}});
            ok $cli->default_account->balance == 0, 'Expected 0 balance after rescind';
        }

        cmp_deeply $rescinder->summary, $expected_summary, 'Expected summary after rescind';

        if (scalar keys $expected_summary->%*) {
            mailbox_clear();
            $rescinder->sendmail;

            my $email = mailbox_search(subject => qr/Automatically rescinded balances on $broker_code/);
            ok $email, 'Email sent';
        }

        mailbox_clear();
        $rescinder->summary({});
        $rescinder->sendmail;

        my $email = mailbox_search(subject => qr/Automatically rescinded balances on $broker_code/);
        ok !$email, 'No summary, no email';

        ok !$rescinder->rescind('CR0', 'USD', 0.99), 'Cannot rescind inexistent client';
    };
}

done_testing;
