use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Log::Any::Test;
use Log::Any qw($log);

use BOM::Platform::Script::TradeWarnings;

use Brands;

my $brand      = Brands->new(name => 'deriv');
my $email_list = join ", ", map { $brand->emails($_) } qw(quants compliance cs marketing_x);
my @message_parameters =
    qw(comment start_time end_time limit_amount current_amount landing_company is_atm expiry_type contract_group market symbol is_market_default);

subtest 'Send email notification when global limit is crossed' => sub {
    my $mocked_warning = Test::MockModule->new('BOM::Platform::Script::TradeWarnings');
    $mocked_warning->mock(
        'send_email',
        sub {
            my $msg = shift;
            # Checking if all of the necessary parameters exist in the email.
            map { is($msg->{message}->[0] =~ /$_/, 1) } @message_parameters;

            $msg->{message} = ['{"is_market_default":0}'];
            is_deeply(
                $msg,
                {
                    from    => 'system@binary.com',
                    message => ['{"is_market_default":0}'],
                    subject => 'Trading suspended! global financial potential loss LIMIT is hit. Limit set: 50. Current amount: 60',
                    to      => $email_list,
                },
                'Email message object is properly created'
            );
        });
    my $notify_msg = {
        binary_user_id  => 1,
        client_loginid  => "CR90000000",
        current_amount  => 60,
        landing_company => "svg",
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
            # Checking if all of the necessary parameters exist in the email.
            map { is($msg->{message}->[0] =~ /$_/, 1) } @message_parameters;

            $msg->{message} = ['{"is_market_default":0}'];
            is_deeply(
                $msg,
                {
                    from    => 'system@binary.com',
                    message => ['{"is_market_default":0}'],
                    subject =>
                        'Trading suspended! user financial potential loss LIMIT is crossed for user 1 loginid CR90000000. Limit set: 50. Current amount: 110',
                    to => $email_list,
                },
                'Email message object is properly created'
            );
        });
    my $notify_msg = {
        binary_user_id  => 1,
        client_loginid  => "CR90000000",
        current_amount  => 110,
        landing_company => "svg",
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
        landing_company => "svg",
        limit_amount    => 50,
        type            => "user_financial_potential_loss"
    };
    my $new_client_limit = 100;
    BOM::Platform::Script::TradeWarnings::_publish($notify_msg, $new_client_limit);
    $log->contains_ok('Client with binary user id 1 crossed a limit of 50', 'Client id and limits logged correctly');
    $log->contains_ok('Skip sending notification email for user_financial_potential_loss on user 1: 60 < 100', 'Log sending email skipped');
};

done_testing;
