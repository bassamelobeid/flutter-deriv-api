use strict;
use warnings;

use BOM::Test::RPC::QueueClient;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use Test::Warnings qw(warning);

my $check_pass = Test::MockModule->new('BOM::RPC::v3::Utility');
$check_pass->mock('check_password', sub { die "in new account for test" });
$check_pass->mock('is_verification_token_valid', {});

subtest 'log detailed error message' => sub {
    my $c = BOM::Test::RPC::QueueClient->new();

    local $ENV{LOG_DETAILED_EXCEPTION} = 1;
    like(
        warning {
            $c->call_ok(
                'new_account_virtual',
                {
                    args => {
                        new_account_virtual => 1,
                        verification_code   => "uoJvVuQ6",
                        client_password     => "Abc123de",
                        residence           => "id"
                    }})
        },
        qr/Exception when handling new_account_virtual. in new account for test at/,
        "exception test",
    );

};

subtest 'log normal error message' => sub {
    my $c = BOM::Test::RPC::QueueClient->new();

    local $ENV{LOG_DETAILED_EXCEPTION} = 0;
    like(
        warning {
            $c->call_ok(
                'new_account_virtual',
                {
                    args => {
                        new_account_virtual => 1,
                        verification_code   => "uoJvVuQ6",
                        client_password     => "Abc123de",
                        residence           => "id"
                    }})
        },
        qr/Exception when handling new_account_virtual. at/,
        "exception test",
    );

};

$check_pass->unmock_all;
done_testing();
