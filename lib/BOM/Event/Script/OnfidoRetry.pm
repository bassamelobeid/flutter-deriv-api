package BOM::Event::Script::OnfidoRetry;

=head1 NAME

BOM::Event::Script::OnfidoRetry - Construct required service objects

=head1 DESCRIPTION

Provides a retry mechanism for stuck in progress onfido checks.

=cut

use strict;
use warnings;

use BOM::Platform::Event::Emitter;
use BOM::Database::UserDB;
use Future::AsyncAwait;
use BOM::Event::Services;
use IO::Async::Loop;
use DataDog::DogStatsd::Helper;

=head2 run

Runs pending checks again.

=cut

async sub run {
    my ($self, $args) = @_;
    my $custom_limit = $args->{custom_limit} // 100;

    my $loop = IO::Async::Loop->new;
    $loop->add(my $services = BOM::Event::Services->new);
    my $onfido = $services->onfido();
    my $checks = BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('select id from users.get_in_progress_onfido_checks(?::INT)', {Slice => {}}, $custom_limit);
        });

    for my $check ($checks->@*) {
        my $onfido_check = await $onfido->check_get(
            check_id => $check->{id},
        );

        next if $onfido_check->status eq 'in_progress';

        DataDog::DogStatsd::Helper::stats_inc('onfido.retry');

        BOM::Platform::Event::Emitter::emit(
            'client_verification',
            {
                check_url => '/v3.4/checks/' . $check->{id},
            });

        await $loop->delay_future(after => 30);
    }

    # db cleanup
    # flag those older hopeless checks as withdrawn

    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('select * from users.withdraw_old_onfido_checks()');
        });
}

1;
