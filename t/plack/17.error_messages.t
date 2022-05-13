use strict;
use warnings;

use FindBin qw/ $Bin /;
use lib "$Bin/lib";

use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::User;

use APIHelper qw(decode_json deposit_validate withdrawal_validate);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);
my $mock_client = Test::MockModule->new('BOM::User::Client');

my $req = deposit_validate(loginid => $client->loginid);
ok decode_json($req->content)->{allowed}, 'Successful deposit validate';

$mock_client->redefine(validate_payment => sub { die {code => 'SelfExclusionLimitExceeded', params => [999, 'USD']} });
$req = deposit_validate(loginid => $client->loginid);
my $msg = decode_json($req->content)->{message};
like $msg, qr(https://app.deriv.com), 'url in SelfExclusionLimitExceeded error (deposit_validate)';
like $msg, qr(999 USD),               'amount in SelfExclusionLimitExceeded error (deposit_validate)';

$mock_client->redefine(validate_payment => sub { die {code => 'BalanceExceeded', params => [998, 'USD']} });
$req = deposit_validate(loginid => $client->loginid);
$msg = decode_json($req->content)->{message};
like $msg, qr(https://app.deriv.com), 'url in BalanceExceeded error (deposit_validate)';
like $msg, qr(998 USD),               'amount in BalanceExceeded error (deposit_validate)';

$mock_client->redefine(validate_payment => sub { die {code => 'WithdrawalLimit', params => [997, 'USD']} });
$req = withdrawal_validate(loginid => $client->loginid);
$msg = decode_json($req->content)->{message};
like $msg, qr(https://app.deriv.com), 'url in WithdrawalLimit error (withdrawal_validate)';
like $msg, qr(997 USD),               'amount in WithdrawalLimit error (withdrawal_validate)';

$mock_client->redefine(validate_payment => sub { die {code => 'WithdrawalLimitReached', params => [996, 'USD']} });
$req = withdrawal_validate(loginid => $client->loginid);
$msg = decode_json($req->content)->{message};
like $msg, qr(https://app.deriv.com), 'url in WithdrawalLimitReached error (withdrawal_validate)';
like $msg, qr(996 USD),               'amount in WithdrawalLimitReached error (withdrawal_validate)';

done_testing();
