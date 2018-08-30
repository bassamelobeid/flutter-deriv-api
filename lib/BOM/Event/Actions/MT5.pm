package BOM::Event::Actions::MT5;

use strict;
use warnings;

no indirect;

use Try::Tiny;

use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'info';

use BOM::Platform::Event::Emitter;
use BOM::User::Client;
use BOM::MT5::User::Async;

=head2 sync_info

Sync user information to MT5

=over 4

=item * C<data> - data passed in from BOM::Event::Process::process

=back

=cut

sub sync_info {
    my $data = shift;
    return undef unless $data->{loginid};

    my $client = BOM::User::Client->new({loginid => $data->{loginid}});
    return 1 if $client->is_virtual;

    my $user = $client->user;
    my @update_operations;

    # TODO: use $user->mt5_logins once it's fixed and it doesn't hit MT5
    for my $mt_login (sort grep { /^MT\d+$/ } $user->loginids) {
        my $operation = BOM::MT5::User::Async::update_user({
                login => do { $mt_login =~ /(\d+)/; $1 },
                %{$client->get_mt5_details()}});

        push @update_operations, $operation;
    }

    my $result = Future->needs_all(@update_operations)->get();

    if ($result->{error}) {
        $log->warn("Failed to sync client $data->{loginid} information to MT5: $result->{error}");
        BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $data->{loginid}});
        return 0;
    }

    return 1;
}

1;
