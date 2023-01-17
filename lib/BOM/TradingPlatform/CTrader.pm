package BOM::TradingPlatform::CTrader;

use strict;
use warnings;
no indirect;

use List::Util qw(any);
use Syntax::Keyword::Try;
use Carp qw(croak);

use BOM::Config::Redis;
use BOM::Platform::Token::API;

use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

=head1 NAME 

BOM::TradingPlatform::CTrader - The cTrader trading platform implementation.

=head1 SYNOPSIS 

    my $dx = BOM::TradingPlatform::CTrader->new(client => $client);

=head1 DESCRIPTION 

Provides a high level implementation of the cTrader API.

Exposes cTrader API through our trading platform interface.

This module must provide support to each cTrader integration within our systems.

=cut

use parent qw(BOM::TradingPlatform);

use constant {
    ONE_TIME_TOKEN_TIMEOUT => 60,                                   # one time token takes 1 minute (60 seconds) to expire.
    ONE_TIME_TOKEN_LENGTH  => 20,
    ONE_TIME_TOKEN_KEY     => 'CTRADER::OAUTH::ONE_TIME_TOKEN::',
};

=head2 new

Creates and returns a new L<BOM::TradingPlatform::CTrader> instance.

=cut

sub new {
    my ($class, %args) = @_;
    return bless +{client => $args{client}}, $class;
}

=head2 generate_login_token

Generates one time login token for cTrader account.
Saves generated token into redis for short period of time.

=cut

sub generate_login_token {
    my ($self, $user_agent) = @_;

    croak 'user_agent is mandatory argument' unless defined $user_agent;

    my ($login) = $self->{client}->user->ctrade_loginids;

    die "No cTrader accounts found for " . $self->{client}->loginid unless $login;

    my $login_details = $self->{client}->user->loginid_details->{$login};

    # Should never happen, it means we have corrupted data in db
    # But because it's json field we cannot enforce at DB level
    die "ctid is not found for $login" unless $login_details->{attributes}{ctid};

    my $one_time_token_params = +{
        ctid       => $login_details->{attributes}{ctid},
        user_agent => $user_agent,
        user_id    => $self->{client}->user->id,
    };

    # 3 attempts just in case of collisions. Normally should be done from first attempt.
    my $redis = BOM::Config::Redis::redis_auth_write;
    for (1 .. 3) {
        my $one_time_token = BOM::Platform::Token::API->new->generate_token(ONE_TIME_TOKEN_LENGTH);

        my $saved = $redis->set(
            ONE_TIME_TOKEN_KEY . $one_time_token,
            encode_json_utf8($one_time_token_params),
            EX => ONE_TIME_TOKEN_TIMEOUT,
            'NX',
        );

        return $one_time_token if $saved;
    }

    die "Fail to generate cTrader login token";
}

=head2 decode_login_token

Validates and one time token and reurns decoded token payload.
In case  not valid token is provided, then exception will be raised.

=cut

sub decode_login_token {
    my ($class, $token) = @_;

    die "INVALID_TOKEN\n" unless length($token // '') == ONE_TIME_TOKEN_LENGTH;

    my $redis = BOM::Config::Redis::redis_auth_write;

    # we need after update to redis 6.2 we can replace with GETDEL  command.
    # For now transaction is the only way to guarantee one time usage
    $redis->multi;
    $redis->get(ONE_TIME_TOKEN_KEY . $token);
    $redis->del(ONE_TIME_TOKEN_KEY . $token);
    my ($payload) = $redis->exec->@*;

    die "INVALID_TOKEN\n" unless $payload;

    my $ott_params;
    try {
        $ott_params = decode_json_utf8($payload);
        # Should never happen, but we're reading data from external source, better to be safe than sorry.
        die if any { !defined $ott_params->{$_} } qw(ctid user_agent user_id);
    } catch {
        die "INVALID_TOKEN\n";
    }

    return $ott_params;
}

1;
