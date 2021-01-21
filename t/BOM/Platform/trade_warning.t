use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Log::Any::Test;
use Log::Any qw($log);

use BOM::Platform::Script::TradeWarnings;

subtest 'Send email notification when global limit is crossed' => sub {
    my $mocked_warning = Test::MockModule->new('BOM::Platform::Script::TradeWarnings');
    $mocked_warning->mock(
        'send_email',
        sub {
            my $msg = shift;
            is_deeply(
                $msg,
                {
                    from    => 'system@binary.com',
                    message => ['{"is_market_default":0}'],
                    subject =>
                        'TRADING SUSPENDED! global_financial_potential_loss LIMIT is crossed for landing company champion. Limit set: 50. Current amount: 60',
                    to => 'x-quants@binary.com,x-marketing@binary.com,compliance@binary.com,x-cs@binary.com'
                },
                'Email message object is properly created'
            );
        });
    my $notify_msg = {
        binary_user_id  => 1,
        client_loginid  => "CR90000000",
        current_amount  => 60,
        landing_company => "champion",
        limit_amount    => 50,
        threshold       => 0.5,
        type            => "global_financial_potential_loss"
    };
    my $new_client_limit = 100;
    BOM::Platform::Script::TradeWarnings::_publish($notify_msg, $new_client_limit);
    $log->contains_ok('Client with binary user id 1 crossed a limit of 50', 'Client id and limits logged correctly');
};

subtest 'Send email notification when user limit is more than or equal to new clients limit' => sub {
    my $mocked_warning = Test::MockModule->new('BOM::Platform::Script::TradeWarnings');
    $mocked_warning->mock(
        'send_email',
        sub {
            my $msg = shift;
            is_deeply(
                $msg,
                {
                    from    => 'system@binary.com',
                    message => ['{"is_market_default":0}'],
                    subject =>
                        'TRADING SUSPENDED! user_financial_potential_loss LIMIT is crossed for user 1 loginid CR90000000. Limit set: 50. Current amount: 110',
                    to => 'x-quants@binary.com,x-marketing@binary.com,compliance@binary.com,x-cs@binary.com'
                },
                'Email message object is properly created'
            );
        });
    my $notify_msg = {
        binary_user_id  => 1,
        client_loginid  => "CR90000000",
        current_amount  => 110,
        landing_company => "champion",
        limit_amount    => 50,
        threshold       => 0.5,
        type            => "user_financial_potential_loss"
    };
    my $new_client_limit = 100;
    BOM::Platform::Script::TradeWarnings::_publish($notify_msg, $new_client_limit);
    $log->contains_ok('Client with binary user id 1 crossed a limit of 50', 'Client id and limits logged correctly');
};

subtest 'Skip sending email when user limit is less than new clients limit' => sub {
    my $mocked_warning = Test::MockModule->new('BOM::Platform::Script::TradeWarnings');
    $mocked_warning->mock(
        'send_email',
        sub {
            die 'We should skip email for client limits less than new_client_limt';
        });
    my $notify_msg = {
        binary_user_id  => 1,
        client_loginid  => "CR90000000",
        current_amount  => 60,
        landing_company => "champion",
        limit_amount    => 50,
        type            => "user_financial_potential_loss"
    };
    my $new_client_limit = 100;
    BOM::Platform::Script::TradeWarnings::_publish($notify_msg, $new_client_limit);
    $log->contains_ok('Client with binary user id 1 crossed a limit of 50', 'Client id and limits logged correctly');
    $log->contains_ok('Skip sending notification email for user_financial_potential_loss on user 1: 60 < 100', 'Log sending email skipped');
};

done_testing;
