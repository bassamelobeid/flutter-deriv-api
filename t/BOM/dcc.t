use BOM::DualControl;
use Test::More;
use Test::Exception;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

subtest 'Checksum for records' => sub {
    my $chk1 = BOM::DualControl::checksum_for_records([1, 2, 3]);

    is $chk1, BOM::DualControl::checksum_for_records([1, 2, 3]), 'Same input gives same checksums';

    isnt $chk1, BOM::DualControl::checksum_for_records([2, 3, 4]), 'Different input gives different checksums';
};

subtest 'Self Tagging DCC' => sub {
    my $dcc1 = BOM::DualControl->new({
            staff           => 'mojtaba',
            transactiontype => 'SELFTAGGING'
        })->self_tagging_control_code();

    my $error = BOM::DualControl->new({
            staff           => 'not_mojtaba',    #someone else should do the DCC
            transactiontype => 'SELFTAGGING'
        })->validate_self_tagging_control_code($dcc1);

    ok !$error, 'No error for same dataset';

};

subtest 'Batch payment DCC' => sub {
    my $dcc1 = BOM::DualControl->new({
            staff           => 'murzilka',
            transactiontype => 'deposit'
        })->batch_payment_control_code([1, 2, 3]);

    my $error = BOM::DualControl->new({
            staff           => 'kirill',
            transactiontype => 'deposit'
        })->validate_batch_payment_control_code($dcc1, [1, 2, 3]);

    ok !$error, 'No error for same dataset';

    my $error = BOM::DualControl->new({
            staff           => 'kirill',
            transactiontype => 'deposit'
        })->validate_batch_payment_control_code($dcc1, [1, 2, 4]);

    ok $error, 'Fail in case dataset is changed';
};

subtest 'payment method DCC' => sub {
    dies_ok {
        BOM::DualControl->new({
                staff           => 'gaurav',
                transactiontype => 'deposit'
            }
        )->payment_control_code('VRTC90000000', 'USD', 500)
    }
    'Should die if client is virtual';
};

subtest 'Batch Anonymization DCC' => sub {
    my $dcc1 = BOM::DualControl->new({
            staff           => 'murzilka',
            transactiontype => 'deposit'
        })->batch_anonymization_control_code([1, 2, 3]);

    my $error = BOM::DualControl->new({
            staff           => 'kirill',
            transactiontype => 'deposit'
        })->validate_batch_anonymization_control_code($dcc1, [1, 2, 3]);

    ok !$error, 'No error for same dataset';

    my $error = BOM::DualControl->new({
            staff           => 'kirill',
            transactiontype => 'deposit'
        })->validate_batch_anonymization_control_code($dcc1, [1, 2, 4]);

    ok $error, 'Fail in case dataset is changed';
};

subtest 'Batch Client Status Update DCC' => sub {
    my $dcc1 = BOM::DualControl->new({
            staff           => 'murzilka',
            transactiontype => 'deposit'
        })->batch_status_update_control_code([1, 2, 3]);

    my $error = BOM::DualControl->new({
            staff           => 'kirill',
            transactiontype => 'deposit'
        })->validate_batch_status_update_control_code($dcc1, [1, 2, 3]);

    ok !$error, 'No error for same dataset';

    my $error = BOM::DualControl->new({
            staff           => 'kirill',
            transactiontype => 'deposit'
        })->validate_batch_status_update_control_code($dcc1, [1, 2, 4]);

    ok $error, 'Fail in case dataset is changed';
};

subtest 'impersonate client dual control code' => sub {
    my $dcc1 = BOM::DualControl->new({
            staff           => 'asdf',
            transactiontype => 'impersonate_code'
        })->create_impersonate_control_code('1234');

    my $error = BOM::DualControl->new({
            staff           => 'not_asdf',          #someone else should do the DCC
            transactiontype => 'impersonate_code'
        })->validate_impersonate_control_code($dcc1, '12344');

    ok $error, 'wrong loginid';
    my $error = BOM::DualControl->new({
            staff           => 'not_asdf',
            transactiontype => 'impersonate_code_123'    #wrong transaction type
        })->validate_impersonate_control_code($dcc1, '12344');

    ok $error, 'wrong transaction type';
    my $error = BOM::DualControl->new({
            staff           => 'not_asdf',
            transactiontype => 'impersonate_code'
        })->validate_impersonate_control_code($dcc1, '1234');
    ok !$error, 'correct loginid and transaction type should work';

};

done_testing();

