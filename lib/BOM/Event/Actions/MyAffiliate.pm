package BOM::Event::Actions::MyAffiliate;

use strict;
use warnings;

use Log::Any qw($log);

use Syntax::Keyword::Try;
use BOM::MyAffiliates;
use BOM::Platform::Event::Emitter;
use BOM::Config;
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use Future::AsyncAwait;
use Future::Utils 'fmap1';
use BOM::MT5::User::Async;
use BOM::Event::Utility qw(exception_logged);
use BOM::Platform::Event::Emitter;

use constant MT5_ACCOUNT_RANGE_SEPARATOR => 10000000;

use constant AFFILIATE_CHUNK_SIZE => 300;

=head2 affiliate_sync_initiated

Initiates the affiliate sync process.

Will fetch the collection of loginids related to this affiliate, split them in chunks and process every chunk separately.

It takes the following arguments:

=over 4

=item * C<affiliate_id> - the id of the affiliate

=back

Retunrs a L<Future> which resolvs to C<undef>

=cut

async sub affiliate_sync_initiated {
    my ($data) = @_;
    my $affiliate_id = $data->{affiliate_id};

    my @login_ids = _get_clean_loginids($affiliate_id)->@*;

    while (my @chunk = splice(@login_ids, 0, AFFILIATE_CHUNK_SIZE)) {
        my $args = {
            login_ids    => [@chunk],
            affiliate_id => $affiliate_id,
            email        => $data->{email},
        };

        # Don't fire a new event if this is the last batch, process it right away instead
        return await affiliate_loginids_sync($args) unless @login_ids;

        BOM::Platform::Event::Emitter::emit('affiliate_loginids_sync', $args);
    }

    return undef;
}

=head2 affiliate_loginids_sync

Process an affiliate loginids by chunks.

It takes the following arguments:

=over 4

=item * C<affiliate_id> - the id of the affiliate

=item * C<login_ids> - the chunk of loginids to be processed in this batch.

=back

Retunrs a L<Future> which resolvs to C<undef>

=cut

async sub affiliate_loginids_sync {
    my ($data)       = @_;
    my $affiliate_id = $data->{affiliate_id};
    my $login_ids    = $data->{login_ids};

    my @results;
    for my $login_id (@$login_ids) {
        my $result = {
            loginid    => $login_id,
            mt5_logins => '',
            error      => ''
        };
        push @results, $result;

        try {
            @{$result}{qw(mt5_logins error)} =
                await _populate_mt5_affiliate_to_client($login_id, $affiliate_id);
        } catch ($e) {
            $result->{error} = $e;
            exception_logged();
        }
    }

    my @added  = map { "For $_->{loginid} to logins " . ($_->{mt5_logins} || 'no mt5 logins') } @results;
    my @errors = map { $_->{error} || () } @results;

    send_email({
            from    => '<no-reply@binary.com>',
            to      => $data->{email},
            subject => "Affliate $affiliate_id synchronization to mt5",
            message => [
                "Synchronization to mt5 for Affiliate $affiliate_id is finished.",
                "List of logins which were synchronized:",
                (@added  ? @added                                                       : ('The affiliate has no clients yet.')),
                (@errors ? ('During synchronization there were these errors:', @errors) : (''))
            ],
        });

    return undef;
}

async sub _populate_mt5_affiliate_to_client {
    my ($loginid, $affiliate_id) = @_;

    my $client = BOM::User::Client->new({loginid => $loginid});
    my $user   = $client->user;

    die "Client with login id $loginid isn't found\n" unless $client;

    my @mt5_logins = $user->mt5_logins;

    my @results = await fmap1(
        async sub {
            my $mt5_login = shift;
            try {
                my $is_success = await _set_affiliate_for_mt5($user, $mt5_login, $affiliate_id);
                return {login => $mt5_login} if $is_success;
                return {};
            } catch ($e) {
                exception_logged();
                return {err => $e};
            }
        },
        foreach    => \@mt5_logins,
        concurrent => 2,
    );

    my @added_logins = map { $_->{login} || () } @results;
    my @errors       = map { $_->{err}   || () } @results;

    return (
        join(q{, } => @added_logins),
        @errors
        ? join(
            qq{\n} => "Errors for client $loginid:",
            @errors
            )
        : '',
    );
}

async sub _set_affiliate_for_mt5 {
    my ($user, $mt5_login, $affiliate_id) = @_;

    # Skip demo accounts
    return 0 if $mt5_login =~ /^MTD/;

    my $user_details = await BOM::MT5::User::Async::get_user($mt5_login);

    return 0 if $user_details->{group} =~ /^demo/;

    if (my $agent_id = $user_details->{agent}) {
        my ($mt5_id) = $mt5_login =~ /${BOM::User->MT5_REGEX}(\d+)/;
        return 0 if (abs($mt5_id - $agent_id) < MT5_ACCOUNT_RANGE_SEPARATOR);
    }

    my $trade_server_id = BOM::MT5::User::Async::get_trading_server_key({login => $mt5_login}, 'real');
    my ($agent_id) = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array(q{SELECT * FROM mt5.get_agent_id(?, ?)}, undef, $affiliate_id, $trade_server_id);
        });

    return 0 unless $agent_id;

    await BOM::MT5::User::Async::update_user({
        %{$user_details},
        login => $mt5_login,
        agent => $agent_id
    });

    return 1;
}

sub _get_clean_loginids {
    my ($affiliate_id) = @_;
    my $my_affiliate   = BOM::MyAffiliates->new();
    my $customers      = $my_affiliate->get_customers(AFFILIATE_ID => $affiliate_id);

    return [
        grep { !/${BOM::User->MT5_REGEX}/ }
        map  { s/^deriv_//r }
        map  { $_->{CLIENT_ID} || () } @$customers
    ];
}

1;
