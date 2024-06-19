use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Exception;
use Email::Address::UseXS;
use BOM::Test::Email qw/mailbox_clear mailbox_search/;

use BOM::Backoffice::Script::CustomerIOTranslation;
use BOM::Platform::Context;

subtest 'customerio sync warning email generation' => sub {
    my $mocked_customerio = Test::MockModule->new('BOM::Backoffice::Script::CustomerIOTranslation');
    $mocked_customerio->mock('update_campaigns_and_snippets', sub { ["Test warning", "Another test warning"] });

    mailbox_clear();

    BOM::Backoffice::Script::CustomerIOTranslation::update_all_envs_and_email_warnings(['token'], undef);

    my @msgs = mailbox_search(
        subject => qr/^Translation errors/,
    );

    ok(@msgs, "find the email");
    like($msgs[0]{body}, qr/Test warning.*Another test warning/ms, "check email body");

    done_testing;
};

done_testing;
