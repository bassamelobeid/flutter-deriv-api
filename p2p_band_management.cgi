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
use BOM::Platform::Event::Emitter;
use Syntax::Keyword::Try;
use Scalar::Util          qw(looks_like_number);
use Scalar::Util::Numeric qw(isint);
use Text::Trim;
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use Log::Any qw($log);

use constant {
    P2P_ADVERTISER_BAND_UPGRADE_PENDING => 'P2P::ADVERTISER_BAND_UPGRADE_PENDING',
};

my $cgi = CGI->new;

PrintContentType();
BrokerPresentation('P2P BAND MANAGEMENT');

my %input  = %{request()->params};
my $broker = request()->broker_code;
my $action = $input{action} // 'new';

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'write'
    })->db->dbic;

my %countries_list = request()->brand->countries_instance->countries_list->%*;
my @countries      = map { {code => $_, name => $countries_list{$_}{name}} }
    sort { $countries_list{$a}{name} cmp $countries_list{$b}{name} } keys %countries_list;

my @currencies = sort @{request()->available_currencies};

if ($input{edit}) {
    Bar('Save band');

    try {
        my @required_fields = qw/max_daily_buy max_daily_sell automatic_approve poa_required email_alert_required/;

        for (
            qw/min_order_amount max_order_amount min_balance max_allowed_dispute_rate
            min_completion_rate min_joined_days min_completed_orders max_allowed_fraud_cases/
            )
        {
            $input{$_} = undef unless trim($input{$_}) ne '';
        }

        die "$_ is required\n" for grep { !defined($input{$_}) } @required_fields;

        for (qw(max_daily_buy max_daily_sell min_order_amount max_order_amount min_balance max_allowed_dispute_rate min_completion_rate)) {
            if ($_ eq "max_allowed_dispute_rate") {
                die "invalid value for $_\n" if defined $input{$_} and not(looks_like_number($input{$_}) && $input{$_} >= 0);
            } else {
                die "invalid value for $_\n" if defined $input{$_} and not(looks_like_number($input{$_}) && $input{$_} > 0);
            }
        }
        for (qw(min_joined_days min_completed_orders max_allowed_fraud_cases)) {
            if ($_ eq "max_allowed_fraud_cases") {
                die "invalid value for $_\n" if defined $input{$_} and not(isint($input{$_}) && $input{$_} >= 0);
            } else {
                die "invalid value for $_\n" if defined $input{$_} and not(isint($input{$_}) && $input{$_} > 0);
            }

        }

        die "min_order_amount cannot be greater than max_order_amount\n" if ($input{min_order_amount} // 0) > ($input{max_order_amount} // 0);

        my $band = $db->run(
            fixup => sub {
                $_->selectrow_hashref(
                    'SELECT max_daily_buy, max_daily_sell, automatic_approve FROM p2p.p2p_country_trade_band WHERE country = ? AND trade_band = LOWER(?) AND currency = ?',
                    undef, @input{qw/country trade_band currency/});
            });

        $db->run(
            fixup => sub {
                $_->do(
                    "UPDATE p2p.p2p_country_trade_band 
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
                         email_alert_required = ? 
                         WHERE country = ? AND trade_band = LOWER(?) AND currency = ?",
                    undef,
                    @input{
                        qw/max_daily_buy max_daily_sell min_order_amount max_order_amount
                            min_balance min_joined_days max_allowed_dispute_rate min_completion_rate
                            min_completed_orders max_allowed_fraud_cases automatic_approve poa_required
                            email_alert_required country trade_band currency/
                    });
            });
        print '<p class="success">Band configuration updated</p>';
        $action = 'new';
        if (($band->{max_daily_buy} != $input{max_daily_buy}) or ($band->{max_daily_sell} != $input{max_daily_sell})) {
            # first need to check if the trade_band has no automatic approve
            if (not($band->{automatic_approve})) {
                my $redis                = BOM::Config::Redis->redis_p2p();
                my %upgradable_band_info = $redis->hgetall(P2P_ADVERTISER_BAND_UPGRADE_PENDING)->@*;
                for my $id (keys %upgradable_band_info) {
                    try {
                        my $target = decode_json_utf8($upgradable_band_info{$id});
                        next if $target->{target_trade_band} ne $input{trade_band};
                        $redis->hdel(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $id);

                        # this event is to send updated advertiser info only to that specific advertiser
                        BOM::Platform::Event::Emitter::emit(
                            p2p_advertiser_updated => {
                                client_loginid => $target->{client_loginid},
                                self_only      => 1,
                            },
                        );

                    } catch ($e) {
                        $log->warnf(
                            'Invalid JSON stored for advertiser id: %s with data: %s at REDIS HASH KEY: %s. Error: %s',
                            $id,
                            $upgradable_band_info{$id},
                            P2P_ADVERTISER_BAND_UPGRADE_PENDING, $e
                        );
                    }
                }

            }
        }

    } catch ($e) {
        print '<p class="error">Failed to save band:' . $e . '</p>';
    }
}

if ($action eq 'delete') {
    Bar('Delete band');
    try {
        $db->run(
            fixup => sub {
                $_->do("DELETE FROM p2p.p2p_country_trade_band WHERE country = ? AND trade_band = LOWER(?) AND currency = ?",
                    undef, @input{qw/country trade_band currency/});
            });
        print '<p class="success">Band deleted</p>';
    } catch ($e) {
        print '<p class="error">Failed to delete band: ' . $e . '</p>';
    }
    delete @input{qw/country trade_band currency max_daily_buy max_daily_sell action/};
    $action = 'new';
}

if ($input{save} or $input{copy}) {
    Bar('Save new band');
    my @required_fields = qw/country trade_band currency max_daily_buy max_daily_sell automatic_approve poa_required email_alert_required/;

    try {
        for (
            qw/min_order_amount max_order_amount min_balance max_allowed_dispute_rate
            min_completion_rate min_joined_days min_completed_orders max_allowed_fraud_cases/
            )
        {
            $input{$_} = undef unless trim($input{$_}) ne '';
        }

        die "$_ is required\n" for grep { !defined($input{$_}) } @required_fields;

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

        for (qw(max_daily_buy max_daily_sell min_order_amount max_order_amount min_balance max_allowed_dispute_rate min_completion_rate)) {
            if ($_ eq "max_allowed_dispute_rate") {
                die "invalid value for $_\n" if defined $input{$_} and not(looks_like_number($input{$_}) && $input{$_} >= 0);
            } else {
                die "invalid value for $_\n" if defined $input{$_} and not(looks_like_number($input{$_}) && $input{$_} > 0);
            }
        }
        for (qw(min_joined_days min_completed_orders max_allowed_fraud_cases)) {
            if ($_ eq "max_allowed_fraud_cases") {
                die "invalid value for $_\n" if defined $input{$_} and not(isint($input{$_}) && $input{$_} >= 0);
            } else {
                die "invalid value for $_\n" if defined $input{$_} and not(isint($input{$_}) && $input{$_} > 0);
            }

        }

        die "min_order_amount cannot be greater than max_order_amount\n" if ($input{min_order_amount} // 0) > ($input{max_order_amount} // 0);

        die "invalid value for Level" unless ($input{trade_band} =~ /^[a-zA-Z_]+$/);

        $db->run(
            fixup => sub {
                $_->do(
                    "INSERT INTO p2p.p2p_country_trade_band (country, trade_band, currency, max_daily_buy, max_daily_sell, min_order_amount, max_order_amount, min_balance,
                          min_joined_days, max_allowed_dispute_rate, min_completion_rate, min_completed_orders, max_allowed_fraud_cases, automatic_approve, poa_required, email_alert_required) 
                     VALUES (?,LOWER(?),?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    undef,
                    @input{
                        qw/country trade_band currency max_daily_buy max_daily_sell min_order_amount max_order_amount
                            min_balance min_joined_days max_allowed_dispute_rate min_completion_rate min_completed_orders
                            max_allowed_fraud_cases automatic_approve poa_required email_alert_required/
                    });
            });
        print '<p class="success">New band configuration saved</p>';
    } catch ($e) {
        print '<p class="error">Failed to save band: ' . $e . '</p>';
    }
    $action = 'new';
}
my $bands = $db->run(
    fixup => sub {
        $_->selectall_arrayref("SELECT * FROM p2p.p2p_country_trade_band ORDER BY country = 'default' DESC, country, trade_band", {Slice => {}});
    });

Bar((ucfirst $action) . ' band');

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_band_edit.tt',
    {
        broker         => $broker,
        item           => \%input,
        countries      => \@countries,
        countries_list => \%countries_list,
        currencies     => \@currencies,
        action         => $action,
    });

Bar('Band configuration for ' . $broker);

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_band_list.tt',
    {
        broker         => $broker,
        bands          => $bands,
        countries_list => \%countries_list,
    });

code_exit_BO();
