use strict;
use warnings;

use Test::More;
use BOM::Platform::CryptoCashier::Iframe::Controller;

subtest 'deposit page warning message' => sub {
    my $currency_code   = 'eUSDT';
    my $warning_message = BOM::Platform::CryptoCashier::Iframe::Controller::deposit_page_warning_message($currency_code);
    is $warning_message,
        'To avoid losing your funds, please use the <strong>Ethereum (ERC20) network</strong> only. Other networks are not supported for eUSDT deposits.',
        'correct warning message for eUSDT/ERC20 currency';

    $currency_code   = 'ETH';
    $warning_message = BOM::Platform::CryptoCashier::Iframe::Controller::deposit_page_warning_message($currency_code);
    is $warning_message,
        'To avoid losing your funds, please use the <strong>Ethereum (ETH) network</strong> only. Other networks are not supported for ETH deposits.',
        'correct warning message for ETH currency';

#   test for currencies which do not have specific warning message
    $currency_code   = 'BTC';
    $warning_message = BOM::Platform::CryptoCashier::Iframe::Controller::deposit_page_warning_message($currency_code);
    like $warning_message, qr/any other digital currency/, 'correct warning message for other currencies';

};

done_testing();
