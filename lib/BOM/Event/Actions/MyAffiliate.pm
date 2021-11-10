package BOM::Event::Actions::MyAffiliate;

use strict;
use warnings;

use Log::Any qw($log);

use Syntax::Keyword::Try;
use BOM::MyAffiliates;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use Future::AsyncAwait;
use Future::Utils 'fmap1';
use BOM::MT5::User::Async;
use BOM::Event::Utility qw(exception_logged);
use BOM::Platform::Event::Emitter;
use List::Util qw(uniq);

use constant AFFILIATE_CHUNK_SIZE => 300;

=head2 affiliate_sync_initiated

Initiates the affiliate sync process.

Will fetch the collection of loginids related to this affiliate, split them in chunks and process every chunk separately.

It takes the following arguments:

=over 4

=item * C<affiliate_id> - the id of the affiliate

=item * C<action> - sync or clear

=item * C<email> - email to notify when done

=back

Retunrs a L<Future> which resolvs to C<undef>

=cut

async sub affiliate_sync_initiated {
    my ($data) = @_;
    my $affiliate_id = $data->{affiliate_id};

    my @loginids = _get_clean_loginids($affiliate_id)->@*;

    while (my @chunk = splice(@loginids, 0, AFFILIATE_CHUNK_SIZE)) {
        my $args = {
            loginids     => [@chunk],
            affiliate_id => $affiliate_id,
            action       => $data->{action},
            email        => $data->{email},
        };

        # Don't fire a new event if this is the last batch, process it right away instead
        return await affiliate_loginids_sync($args) unless @loginids;

        BOM::Platform::Event::Emitter::emit('affiliate_loginids_sync', $args);
    }

    return undef;
}

=head2 affiliate_loginids_sync

Process an affiliate loginids by chunks.

It takes the following arguments:

=over 4

=item * C<affiliate_id> - the id of the affiliate

=item * C<loginids> - the chunk of loginids to be processed in this batch.

=item * C<action> - sync or clear

=item * C<email> - email to notify when done

=back

Retunrs a L<Future> which resolves to C<undef>

=cut

async sub affiliate_loginids_sync {
    my ($data) = @_;
    my ($affiliate_id, $loginids, $action) = $data->@{qw/affiliate_id loginids action/};

    my @results;
    for my $loginid (@$loginids) {
        try {
            my $result = await _populate_mt5_affiliate_to_client($loginid, $action eq 'clear' ? undef : $affiliate_id);
            push @results, @$result;
        } catch ($e) {
            push @results, "$loginid: an error occured: $e";
            exception_logged();
        }
    }

    send_email({
            from    => '<no-reply@binary.com>',
            to      => $data->{email},
            subject => "Affliate $affiliate_id synchronization to mt5",
            message => [
                "Synchronization to mt5 for Affiliate $affiliate_id is finished.",
                'Action: ' . ($action eq 'clear' ? 'remove agent from all clients.' : 'sync agent with all clients.'),
                '-' x 20, sort @results,
            ],
        });

    return undef;
}

async sub _populate_mt5_affiliate_to_client {
    my ($loginid, $affiliate_id) = @_;

    my $client = BOM::User::Client->new({loginid => $loginid});
    return ["$loginid: not a valid loginid"] unless $client;

    my $user       = $client->user;
    my @mt5_logins = $user->mt5_logins;

    my @results = await fmap1(
        async sub {
            my $mt5_login = shift;
            try {
                my $result = await _set_affiliate_for_mt5($user, $mt5_login, $affiliate_id);
                return defined $result ? "$loginid: account $mt5_login agent updated to $result" : undef;
            } catch ($e) {
                exception_logged();
                return "$loginid: account $mt5_login had an error: $e";
            }
        },
        foreach    => \@mt5_logins,
        concurrent => 2,
    );

    return [grep { defined } @results];
}

async sub _set_affiliate_for_mt5 {
    my ($user, $mt5_login, $affiliate_id) = @_;

    # Skip demo accounts
    return if $mt5_login =~ /^MTD/;

    my $user_details = await BOM::MT5::User::Async::get_user($mt5_login);

    return if $user_details->{group} =~ /^demo/;

    my $agent_id;
    if ($affiliate_id) {
        my $trade_server_id = BOM::MT5::User::Async::get_trading_server_key({login => $mt5_login}, 'real');
        ($agent_id) = $user->dbic->run(
            fixup => sub {
                $_->selectrow_array(q{SELECT * FROM mt5.get_agent_id(?, ?)}, undef, $affiliate_id, $trade_server_id);
            });
    }

    $agent_id //= 0;

    # no update needed
    return if $agent_id == ($user_details->{agent} // 0);

    await BOM::MT5::User::Async::update_user({
        %{$user_details},
        login => $mt5_login,
        agent => $agent_id,
    });

    return $agent_id;
}

sub _get_clean_loginids {
    my ($affiliate_id) = @_;
    my $my_affiliate   = BOM::MyAffiliates->new();
    my $customers      = $my_affiliate->get_customers(AFFILIATE_ID => $affiliate_id);

    return [
        uniq
            grep { !/${BOM::User->MT5_REGEX}/ }
            map  { s/^deriv_//r }
            map  { $_->{CLIENT_ID} || () } @$customers
    ];
}

1;
