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

async sub affiliate_sync_initiated {
    my ($data)              = @_;
    my $affiliate_id        = $data->{affiliate_id};
    my $affiliate_mt5_login = $data->{mt5_login};

    my $my_affiliate = BOM::MyAffiliates->new();
    my $customers = $my_affiliate->get_customers(AFFILIATE_ID => $affiliate_id);

    my @login_ids = map { $_->{CLIENT_ID} || () } @$customers;

    my @results;
    for my $login_id (@login_ids) {
        my $result = {
            loginid    => $login_id,
            mt5_logins => '',
            error      => ''
        };
        push @results, $result;

        try {
            @{$result}{qw(mt5_logins error)} =
                await _populate_mt5_affiliate_to_client($login_id, $affiliate_mt5_login);
        }
        catch {
            $result->{error} = $@;
        }
    }

    my @added = map { "For $_->{loginid} to logins " . ($_->{mt5_logins} || 'no mt5 logins') } @results;
    my @errors = map { $_->{error} || () } @results;

    send_email({
            from    => '<no-reply@binary.com>',
            to      => $data->{email},
            subject => "Affliate $affiliate_id synchronization to mt5",
            message => [
                "Synchronization to mt5 for Affiliate $affiliate_id is finished.",
                "List of logins which were synchronized:",
                (@added ? @added : ('The affiliate has no clients yet.')),
                (@errors ? ('During synchronization there were these errors:', @errors) : (''))
            ],
        });
}

async sub _populate_mt5_affiliate_to_client {
    my ($loginid, $affiliate_mt5_login) = @_;

    my $client = BOM::User::Client->new({loginid => $loginid});

    die "Client with login id $loginid isn't found\n" unless $client;

    my @mt5_logins = $client->user->mt5_logins;

    my @results = await fmap1(
        async sub {
            my $mt5_login = shift;
            try {
                my $is_success = await _set_affiliate_for_mt5($mt5_login, $affiliate_mt5_login);
                return {login => $mt5_login} if $is_success;
                return {};
            }
            catch {
                return {err => $@};
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
    my ($mt5_login, $affiliate_mt5_login) = @_;

    my $mt5_login_id = $mt5_login =~ s/^MT//r;
    my $user_details = await BOM::MT5::User::Async::get_user($mt5_login_id);

    return 0 if $user_details->{group} ne 'real\\svg';
    return 0 if $user_details->{agent};

    await BOM::MT5::User::Async::update_user({
        %{$user_details},
        login => $mt5_login_id,
        agent => $affiliate_mt5_login
    });

    return 1;
}

1;
