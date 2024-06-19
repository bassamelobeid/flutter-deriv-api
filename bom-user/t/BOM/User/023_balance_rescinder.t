use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::User::Script::BalanceRescinder;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(top_up);
use BOM::Test::Email;
use LandingCompany::Registry;

my @broker_codes = LandingCompany::Registry->all_real_broker_codes();

my $fake_rates = {
    BTC  => 0.0000001,
    LTC  => 0.000021,
    ETH  => 0.0000003,
    EURS => 0.9
};

my $mock = Test::MockModule->new('BOM::User::Script::BalanceRescinder');

$mock->mock(
    'convert_currency',
    sub {
        my ($amount, undef, $currency) = @_;

        return $amount * ($fake_rates->{$currency} // 1);
    });

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

for my $broker_code (@broker_codes) {
    subtest "Testing $broker_code" => sub {
        my $dbic = BOM::Database::ClientDB->new({
                broker_code  => $broker_code,
                db_operation => 'write',
            })->db->dbic;

        $dbic->run(
            fixup => sub {
                $_->do("DELETE FROM betonmarkets.client_status WHERE status_code = 'disabled'");
            });

        my $rescinder = BOM::User::Script::BalanceRescinder->new(broker_code => $broker_code);
        isa_ok($rescinder, 'BOM::User::Script::BalanceRescinder');
        is($rescinder->broker_code, $broker_code, 'Correct broker code');

        my $currencies = $rescinder->currencies(1);

        for my $curr (keys $currencies->%*) {
            my $type   = $rescinder->landing_company->legal_allowed_currencies->{$curr}->{type};
            my $stable = $rescinder->landing_company->legal_allowed_currencies->{$curr}->{stable};

            my $expected_value = ($type eq 'fiat' || $stable) ? 1 : ($fake_rates->{$curr} // 1);
            is $currencies->{$curr}, $expected_value, "We got the expected value for $curr";
        }

        # Create the accounts
        my %expected_to_rescind;
        my %client_stash;

        for my $cli_settings ($clients->@*) {
            next unless grep { $_ eq $cli_settings->{currency} } keys $rescinder->landing_company->legal_allowed_currencies->%*;
            my $cli = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => $broker_code,
            });
            $cli->set_default_account($cli_settings->{currency});
            $client_stash{$cli->loginid} = 1;

            # there is no way to fake the time of statuses :(
            $cli->status->set('disabled', 'test', 'test') if $cli_settings->{disabled};
            top_up($cli, $cli_settings->{currency}, $cli_settings->{balance}, 'test_account');
            ok $cli->default_account->balance - $cli_settings->{balance} == 0, 'Expected balance after top up';
            $expected_to_rescind{$cli->loginid} = $cli_settings->{balance} if $cli_settings->{rescind};
        }

        # we are asking for disabled accounts from 30 days in the past, this won't hit any recently created account.
        my $res = $rescinder->process_accounts(
            desc     => 'test',
            days     => 30,
            amount   => 1,
            statuses => ['disabled']);
        is $res, undef, 'None of the accounts were disabled for more than 30 days';

        # we will fetch disabled accounts from 1 day in the future (-1) so all the accounts are within range
        $res = $rescinder->process_accounts(
            desc     => 'test',
            days     => -1,
            amount   => 1,
            statuses => ['disabled']);

        my %rescinded = map { $_->{client_loginid} => $_ } @$res;
        cmp_deeply [keys %rescinded], bag(keys %expected_to_rescind), 'We got the expected accounts to rescind';

        for my $loginid (keys %expected_to_rescind) {
            my $cli = BOM::User::Client->new({loginid => $loginid});
            ok $cli->default_account->balance == 0, 'Expected 0 balance after rescind';

            is $rescinded{$loginid}->{currency_code}, $cli->currency, 'currency in summary';
            cmp_ok $rescinded{$loginid}->{balance}, '==', $expected_to_rescind{$loginid}, 'balance in summary';
            cmp_deeply $rescinded{$loginid}->{statuses}, ['disabled'], 'statuses in summary';
            is $rescinded{$loginid}->{error}, undef, 'error is undef in summary';
        }

        mailbox_clear();
        $rescinder->sendmail({'test' => $res});
        my $email = mailbox_search(subject => qr/Automatically rescinded balances on $broker_code/);
        ok $email, 'Email sent';

        mailbox_clear();
        $rescinder->sendmail({'test' => undef});
        $email = mailbox_search(subject => qr/Automatically rescinded balances on $broker_code/);
        ok !$email, 'No summary, no email';

        is $rescinder->rescind(
            client_loginid => 'CR0',
            currency_code  => 'USD',
            balance        => 0.99
            ),
            'No client', 'Cannot rescind inexistent client';
    };
}

$clients = [{
        disabled => 1,
        currency => 'USD',
        balance  => 499,
        rescind  => 1,
    },
    {
        disabled => 0,
        currency => 'USD',
        balance  => 500,
        rescind  => 0,
    },
    {
        disabled   => 1,
        currency   => 'USD',
        balance    => 500,
        rescind    => 1,
        only_if_cr => 1,
    }];

for my $broker_code (@broker_codes) {
    subtest "Testing $broker_code for NULL amounts (disregard the client balance)" => sub {
        my $dbic = BOM::Database::ClientDB->new({
                broker_code  => $broker_code,
                db_operation => 'write',
            })->db->dbic;

        $dbic->run(
            fixup => sub {
                $_->do("DELETE FROM betonmarkets.client_status WHERE status_code = 'disabled'");
            });

        my $rescinder = BOM::User::Script::BalanceRescinder->new(broker_code => $broker_code);
        isa_ok($rescinder, 'BOM::User::Script::BalanceRescinder');
        is($rescinder->broker_code, $broker_code, 'Correct broker code');

        my $currencies = $rescinder->currencies(undef);

        for my $curr (keys $currencies->%*) {
            my $type   = $rescinder->landing_company->legal_allowed_currencies->{$curr}->{type};
            my $stable = $rescinder->landing_company->legal_allowed_currencies->{$curr}->{stable};

            is $currencies->{$curr}, undef, "We got the expected value for $curr";
        }

        # Create the accounts
        my %expected_to_rescind;
        my %client_stash;

        for my $cli_settings ($clients->@*) {
            next unless grep { $_ eq $cli_settings->{currency} } keys $rescinder->landing_company->legal_allowed_currencies->%*;
            my $cli = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => $broker_code,
            });
            $cli->set_default_account($cli_settings->{currency});
            $client_stash{$cli->loginid} = 1;
            # there is no way to fake the time of statuses :(
            $cli->status->set('disabled', 'test', 'test') if $cli_settings->{disabled};
            top_up($cli, $cli_settings->{currency}, $cli_settings->{balance}, 'test_account');
            ok $cli->default_account->balance - $cli_settings->{balance} == 0, 'Expected balance after top up';
            $expected_to_rescind{$cli->loginid} = $cli_settings->{balance} if $cli_settings->{rescind};

            if ($cli_settings->{only_if_cr}) {
                delete $expected_to_rescind{$cli->loginid} if $broker_code ne 'CR';
            }
        }
        # we are asking for disabled accounts from 30 days in the past, this won't hit any recently created account.
        my $res = $rescinder->process_accounts(
            desc     => 'test',
            days     => 30,
            amount   => undef,
            statuses => ['disabled']);
        is $res, undef, 'None of the accounts were disabled for more than 30 days';

        # negative amount test only if CR (negative days to )
        $res = $rescinder->process_accounts(
            desc         => 'test',
            days         => -1,
            amount       => undef,
            statuses     => ['disabled'],
            broker_codes => [qw/CR/]);

        if ($broker_code ne 'CR') {
            is $res, undef, 'undef for non CR broker code';
        } else {
            my %rescinded = map { $_->{client_loginid} => $_ } @$res;
            cmp_deeply [keys %rescinded], bag(keys %expected_to_rescind), 'We got the expected accounts to rescind';

            for my $loginid (keys %expected_to_rescind) {
                my $cli = BOM::User::Client->new({loginid => $loginid});
                ok $cli->default_account->balance == 0, 'Expected 0 balance after rescind';

                is $rescinded{$loginid}->{currency_code}, $cli->currency, 'currency in summary';
                cmp_ok $rescinded{$loginid}->{balance}, '==', $expected_to_rescind{$loginid}, 'balance in summary';
                cmp_deeply $rescinded{$loginid}->{statuses}, ['disabled'], 'statuses in summary';
                is $rescinded{$loginid}->{error}, undef, 'error is undef in summary';
            }

            mailbox_clear();
            $rescinder->sendmail({'test' => $res});
            my $email = mailbox_search(subject => qr/Automatically rescinded balances on $broker_code/);
            ok $email, 'Email sent';

            mailbox_clear();
            $rescinder->sendmail({'test' => undef});
            $email = mailbox_search(subject => qr/Automatically rescinded balances on $broker_code/);
            ok !$email, 'No summary, no email';

            is $rescinder->rescind(
                client_loginid => 'CR0',
                currency_code  => 'USD',
                balance        => 0.99
                ),
                'No client', 'Cannot rescind inexistent client';
        }
    };
}

done_testing;
