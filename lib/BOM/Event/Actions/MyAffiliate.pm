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

use constant MT5_ACCOUNT_RANGE_SEPARATOR => 10000000;

async sub affiliate_sync_initiated {
    my ($data) = @_;
    my $affiliate_id = $data->{affiliate_id};

    my $login_ids = _get_clean_loginids($affiliate_id);
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
