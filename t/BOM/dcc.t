use BOM::DualControl;
use Test::More;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

subtest 'Checksum for records' => sub {
    my $chk1 = BOM::DualControl::checksum_for_records([1, 2, 3]);

    is $chk1, BOM::DualControl::checksum_for_records([1, 2, 3]), 'Same input gives same checksums';

    isnt $chk1, BOM::DualControl::checksum_for_records([2, 3, 4]), 'Different input gives different checksums';
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

done_testing();

