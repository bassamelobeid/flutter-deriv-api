use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use BOM::Platform::Transaction;
use BOM::Database::DataMapper::Payment::FreeGift;
use BOM::Database::DataMapper::Transaction;
use File::Flock::Tiny;

########################################################################
# Rescind_FreeGifts('CR',90,'Do it for real !','Rescind of free gift for cause of inactivity');
# will remove all free gifts from accounts with unused free gifts for over 90 days (i.e. with just 1 line in client a/c)
########################################################################
sub Rescind_FreeGifts {
    my ($broker, $inactivedays, $whattodo, $message, $clerk) = @_;

    my $lockname = "/var/lock/rescind-free-gifts.lock";
    my $lock     = File::Flock::Tiny->trylock("/var/lock/rescind-free-gifts.lock");
    unless ($lock and (stat $lock)[1] == (stat $lockname)[1]) {
        die "Another process already rescinding free gifts, try again later";
    }

    $message ||= 'Rescind of free gift for cause of inactivity';
    $clerk   ||= 'system';

    my @report;

    my $freegift_mapper = BOM::Database::DataMapper::Payment::FreeGift->new({
        broker_code => $broker,
    });

    my $now                       = BOM::Utility::Date->new;
    my $befor_than                = BOM::Utility::Date->new(($now->epoch - ($inactivedays * 24 * 60 * 60)))->truncate_to_day;
    my $account_dont_use_freegift = $freegift_mapper->get_clients_with_only_one_freegift_transaction_and_inactive($befor_than);
    LOGINID:
    foreach my $account (@{$account_dont_use_freegift}) {
        my $creditamount = $account->{'amount'};
        my $curr         = $account->{'currency_code'};
        my $loginID      = $account->{'client_loginid'};
        my $txn_date     = $account->{'transaction_time'};

        my $client = BOM::Platform::Client->new({loginid => $loginID});

        if (not BOM::Platform::Transaction->freeze_client($loginID)) {
            die "Account stuck in previous transaction $loginID";
        }

        my $bal = $client->default_account->balance;
        if ($creditamount != $bal) {
            push @report, "$loginID Error with $creditamount != $bal";
        } else {
            push @report, "$loginID, Amount: $curr $bal, Funded date: $txn_date";
            if ($whattodo eq 'Do it for real !') {
                $client->payment_free_gift(
                    currency => $curr,
                    amount   => -$bal,
                    remark   => $message,
                    staff    => $clerk,
                );
                push @report, "$loginID rescinded $curr $bal!";
            }
        }
        BOM::Platform::Transaction->unfreeze_client($loginID);
    }

    unlink $lockname;

    return @report;
}

1;
