#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
BOM::Backoffice::Sysinit::init();

use BOM::Database::ClientDB;
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Platform::Event::Emitter;
use Syntax::Keyword::Try;
use Scalar::Util          qw(looks_like_number);
use Scalar::Util::Numeric qw(isint);
use List::Util            qw(any);
use Text::Trim;
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use Log::Any qw($log);
use Data::Dumper;

use constant {
    P2P_ADVERTISER_BAND_UPGRADE_PENDING => 'P2P::ADVERTISER_BAND_UPGRADE_PENDING',
};

my $cgi = CGI->new;

PrintContentType();
BrokerPresentation('P2P BAND MANAGEMENT');

my %params = request()->params->%*;
my %input  = map { $_ => $params{$_} } grep { length(trim($params{$_})) } keys %params;

my $broker = request()->broker_code;
my $action = $input{action} // '';

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'write'
    })->db->dbic;

my %countries_list = request()->brand->countries_instance->countries_list->%*;
my @countries      = map { {code => $_, name => $countries_list{$_}{name}} }
    sort { $countries_list{$a}{name} cmp $countries_list{$b}{name} } keys %countries_list;

my @currencies = sort map { uc $_ } BOM::Config::Runtime->instance->app_config->payments->p2p->available_for_currencies->@*;

if ($action eq 'update') {
    Bar('Save band');

    try {
        %input = validate_input(%input)->%*;

        my $existing = $db->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM p2p.p2p_country_trade_band WHERE country = ? AND trade_band = LOWER(?) AND currency = ?',
                    undef, @input{qw/country trade_band currency/});
            });

        $db->run(
            fixup => sub {
                $_->do(
                    'UPDATE p2p.p2p_country_trade_band 
                        SET max_daily_buy = ?,
                            max_daily_sell = ?, 
                            min_order_amount = ?, 
                            max_order_amount = ?, 
                            min_balance = ?,
                            min_joined_days = ?,
                            max_allowed_dispute_rate = ?,
                            min_completion_rate = ?,
                            min_completed_orders = ?,
                            max_allowed_fraud_cases = ?,
                            automatic_approve = ?,
                            poa_required = ?,
                            email_alert_required = ?,
                            block_trade_min_order_amount = ?,
                            block_trade_max_order_amount = ?,
                            min_turnover = ?,
                            payment_agent_tier = ?
                      WHERE country = ? 
                        AND trade_band = LOWER(?) 
                        AND currency = ?',
                    undef,
                    @input{
                        qw/max_daily_buy max_daily_sell min_order_amount max_order_amount
                            min_balance min_joined_days max_allowed_dispute_rate min_completion_rate
                            min_completed_orders max_allowed_fraud_cases automatic_approve poa_required
                            email_alert_required block_trade_min_order_amount block_trade_max_order_amount
                            min_turnover payment_agent_tier country trade_band currency /
                    });
            });

        printf '<p class="success">Band %s %s %s updated</p>', @input{qw(trade_band country currency)};
        $action = '';
        undef %input;

        if (any { ($existing->{$_} // -1) != ($input{$_} // -1) }
            qw(max_daily_buy max_daily_sell block_trade_min_order_amount block_trade_max_order_amount))
        {
            clear_band_upgrades($existing->{trade_band});
        }

    } catch ($e) {
        print '<p class="error">Failed to save band: ' . (ref $e ? Dumper($e) : $e) . '</p>';
    }
}

if ($action eq 'delete') {
    Bar('Delete band');

    try {
        my $deleted = $db->run(
            fixup => sub {
                $_->selectrow_hashref(
                    'DELETE FROM p2p.p2p_country_trade_band WHERE country = ? AND trade_band = LOWER(?) AND currency = ? RETURNING *',
                    undef, @input{qw/country trade_band currency/});
            });
        printf '<p class="success">Band %s %s %s deleted</p>', $deleted->@{qw(trade_band country currency)};

        clear_band_upgrades($deleted->{trade_band});

    } catch ($e) {
        print '<p class="error">Failed to delete band: ' . (ref $e ? Dumper($e) : $e) . '</p>';
    }

    $action = '';
    undef %input;
}

if ($action eq 'create') {
    Bar('Save new band');

    try {
        %input = validate_input(%input)->%*;

        my ($existing) = $db->run(
            fixup => sub {
                $_->selectrow_array('SELECT COUNT(*) FROM p2p.p2p_country_trade_band WHERE country = ? AND trade_band = LOWER(?) AND currency = ?',
                    undef, @input{qw/country trade_band currency/});
            });

        die 'level '
            . $input{trade_band}
            . ' already exists for '
            . ($countries_list{$input{country}}{name} // 'default country')
            . ' and currency '
            . $input{currency} . "\n"
            if $existing;

        $db->run(
            fixup => sub {
                $_->do(
                    "INSERT INTO p2p.p2p_country_trade_band (country, trade_band, currency, max_daily_buy, max_daily_sell, min_order_amount, max_order_amount, min_balance,
                          min_joined_days, max_allowed_dispute_rate, min_completion_rate, min_completed_orders, max_allowed_fraud_cases, automatic_approve, poa_required, 
                          email_alert_required, block_trade_min_order_amount, block_trade_max_order_amount, min_turnover, payment_agent_tier)
                     VALUES (?,LOWER(?),?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    undef,
                    @input{
                        qw/country trade_band currency max_daily_buy max_daily_sell min_order_amount max_order_amount min_balance
                            min_joined_days max_allowed_dispute_rate min_completion_rate min_completed_orders max_allowed_fraud_cases automatic_approve poa_required
                            email_alert_required block_trade_min_order_amount block_trade_max_order_amount min_turnover payment_agent_tier/
                    });
            });
        print '<p class="success">New band configuration saved</p>';
        undef %input;

    } catch ($e) {
        print '<p class="error">Failed to save band: ' . (ref $e ? Dumper($e) : $e) . '</p>';
    }
}

$action = 'update' if $action eq 'edit';
$action = 'create' if $action eq 'copy';
undef %input if $input{cancel};
$action ||= 'create';
Bar((ucfirst $action) . ' band');

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_band_edit.tt',
    {
        action         => $action,
        item           => \%input,
        countries      => \@countries,
        countries_list => \%countries_list,
        currencies     => \@currencies,
        broker         => $broker,
    });

Bar('Band configuration for ' . $broker);

my $bands = $db->run(
    fixup => sub {
        $_->selectall_arrayref("SELECT * FROM p2p.p2p_country_trade_band ORDER BY country = 'default' DESC, country, trade_band", {Slice => {}});
    });

for my $band (@$bands) {
    next if (!defined $band->{automatic_approve}) && ($band->{upgrade_type} = 'none');
    next if $band->{automatic_approve}            && ($band->{upgrade_type} = 'auto');
    $band->{upgrade_type} = $band->{email_alert_required} ? 'manual_with_email' : 'manual';
}

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_band_list.tt',
    {
        broker         => $broker,
        bands          => $bands,
        countries_list => \%countries_list,
    });

code_exit_BO();

sub validate_input {
    my %input = @_;

    die "$_ is required\n" for grep { !defined($input{$_}) } qw(trade_band country currency max_daily_buy max_daily_sell poa_required upgrade_type);

    die "$_ can contain only letters and underscores\n" for grep { $input{$_} !~ /^[a-zA-Z_]+$/ } qw(country trade_band currency);

    die "$_ must be numeric\n"
        for grep { defined $input{$_} && !looks_like_number($input{$_}) }
        qw(max_daily_buy max_daily_sell min_order_amount max_order_amount min_balance max_allowed_dispute_rate min_completion_rate
        block_trade_min_order_amount block_trade_max_order_amount min_turnover);

    die "$_ must be an integer\n"
        for grep { defined $input{$_} && !isint($input{$_}) } qw(min_joined_days min_completed_orders max_allowed_fraud_cases);

    die "$_ must be greater than 0\n"
        for grep { defined $input{$_} && $input{$_} <= 0 }
        qw(max_daily_buy max_daily_sell min_order_amount max_order_amount min_balance max block_trade_min_order_amount block_trade_max_order_amount
        min_turnover min_joined_days min_completed_orders);

    die "$_ cannot be negative\n" for grep { defined $input{$_} && $input{$_} < 0 } qw(max_allowed_fraud_cases);

    die "the range for $_ is 0 - 1\n"
        for grep { defined $input{$_} && ($input{$_} < 0 || $input{$_} > 1) } qw(max_allowed_dispute_rate min_completion_rate);

    die "Minimum Ad Order Limit cannot be greater than Maximum Ad Order Limit\n" if ($input{min_order_amount} // 0) > ($input{max_order_amount} // 0);

    die "Block Trade Minimum Ad Order Limit and Block Trade Maximum Ad Order Limit must both have a value or be empty\n"
        unless (defined $input{block_trade_min_order_amount} // 0) == (defined $input{block_trade_max_order_amount} // 0);

    die "Block Trade Minimum Ad Order Limit cannot be greater than Block Trade Maximum Ad Order Limit\n"
        if ($input{block_trade_min_order_amount} // 0) > ($input{block_trade_max_order_amount} // 0);

    die "Maximum Ad Order Limit for normal ads cannot be greater than Block Trade Minimum Ad Order Limit\n"
        if defined $input{block_trade_min_order_amount} and ($input{max_order_amount} // 0) > $input{block_trade_min_order_amount};

    my %upgrade_types = (
        none => {
            automatic_approve    => undef,
            email_alert_required => 0,
        },
        auto => {
            automatic_approve    => 1,
            email_alert_required => 0,
        },
        manual => {
            automatic_approve    => 0,
            email_alert_required => 0,
        },
        manual_with_email => {
            automatic_approve    => 0,
            email_alert_required => 1,
        },
    );

    %input = (%input, $upgrade_types{$input{upgrade_type}}->%*);
    return \%input;
}

sub clear_band_upgrades {
    my $band_name = shift;

    my $redis = BOM::Config::Redis->redis_p2p_write();

    my %pending_upgrades = $redis->hgetall(P2P_ADVERTISER_BAND_UPGRADE_PENDING)->@*;

    for my $id (keys %pending_upgrades) {
        try {
            my $upgrade = decode_json_utf8($pending_upgrades{$id});
            next if $upgrade->{target_trade_band} ne $band_name;

            $redis->hdel(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $id);

            # this event is to send updated advertiser info only to that specific advertiser
            BOM::Platform::Event::Emitter::emit(
                p2p_advertiser_updated => {
                    client_loginid => $upgrade->{client_loginid},
                    self_only      => 1,
                },
            );
        } catch ($e) {
            $log->warnf('Invalid JSON stored for advertiser id: %s with data: %s in key: %s. Error: %s',
                $id, $pending_upgrades{$id}, P2P_ADVERTISER_BAND_UPGRADE_PENDING, $e);
        }
    }
}
