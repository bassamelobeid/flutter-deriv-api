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
use Syntax::Keyword::Try;
use Date::Utility;
use BOM::Config::Runtime;
use BOM::Config;
use BOM::Config::Redis;
use Scalar::Util          qw(looks_like_number);
use Format::Util::Numbers qw(financialrounding);
use BOM::Platform::Event::Emitter;
use JSON::MaybeXS;
use DateTime;
use DateTime::TimeZone;
use BOM::P2P::BOUtility;
use Log::Any qw($log);

my $cgi = CGI->new;

PrintContentType();
BrokerPresentation(' ');

my $config         = BOM::Config::third_party();
my $sendbird_token = $config->{sendbird}->{api_token};

my %input  = %{request()->params};
my $broker = request()->broker_code;

my %dispute_reasons = (
    seller_not_released              => 'Seller did not release funds',
    buyer_overpaid                   => 'Buyer paid too much',
    buyer_underpaid                  => 'Buyer paid less',
    buyer_not_paid                   => 'Buyer has not made any payment',
    buyer_third_party_payment_method => 'Buyer paid with the help of third party'
);

use constant TRANSACTION_MAPPER => {
    order_create => {
        src_loginid  => 'seller',
        dest_loginid => 'escrow'
    },
    order_complete_escrow => {
        src_loginid  => 'escrow',
        dest_loginid => 'seller'
    },
    order_complete_payment => {
        src_loginid  => 'seller',
        dest_loginid => 'buyer'
    },
    order_cancel => {
        src_loginid  => 'escrow',
        dest_loginid => 'seller'
    },
};

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'backoffice_replica'
    })->db->dbic;

my $db_collector = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
    })->db->dbic;

my ($order, @transactions, $history, $chat_messages, @verification_history, %timezones, %schedules);
my $chat_messages_limit = 20;
my $chat_page           = int($input{p} // 1);
my $tz_offset           = 0;

$chat_page = 1
    unless $chat_page > 0;    # The default page is 1 so math is well adjusted

Bar('P2P Order details/management');

my $can_dispute = BOM::Backoffice::Auth::has_authorisation(['P2PWrite', 'P2PAdmin', 'AntiFraud']);

if ($input{action}) {
    try {
        die "You do not have permission to resolve disputes\n" unless $can_dispute;
        my $client = BOM::User::Client->new({loginid => $input{disputer}});
        my $res    = $client->p2p_resolve_order_dispute(
            id     => $input{order_id},
            action => $input{action},
            fraud  => $input{fraud},
            staff  => substr(BOM::Backoffice::Auth::get_staff_nickname(BOM::Backoffice::Auth::get_staff()), 0, 24)
            ,  #We are trimming because staff_loginid column in transaction table cannot hold more than 24 chars, in same time these users are unique.
        );
        die "DB error $res->{error} occurred. Please try again and contact backend if it keeps happening." if $res->{error};
    } catch ($e) {
        $e = join ', ', $e->@* if ref $e eq 'ARRAY';
        print '<p class="error">' . $e . '</p>';
    }
}

if ($input{dispute}) {
    try {
        die "You do not have permission to create disputes\n" unless $can_dispute;
        die "Invalid dispute reason.\n"                       unless exists $dispute_reasons{$input{reason}};

        my $client = BOM::User::Client->new({loginid => $input{disputer}});
        $client->p2p_create_order_dispute(
            skip_livechat  => 1,
            id             => $input{order_id},
            dispute_reason => $input{reason});

    } catch ($e) {
        my $error = $e;
        $error = join ', ', $e->@* if ref $e eq 'ARRAY';
        $error = $e->{error_code}
            if ref $e eq 'HASH' && defined $e->{error_code};
        print '<p class="error">' . $error . '</p>';
    }
}

if (my $id = $input{order_id}) {
    try {
        $order = $db->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM p2p.order_list(?,NULL,NULL,NULL,NULL,NULL)', undef, $id);
            });
        die "Order $id not found\n" unless $order;

        if ($input{tz} && $input{tz} ne 'UST') {
            my $tz = DateTime::TimeZone->new(name => $input{tz});
            $tz_offset = $tz->offset_for_datetime(DateTime->now());
        }

        if ($order->{type} eq 'buy') {
            $order->{client_role}     = 'BUYER';
            $order->{advertiser_role} = 'SELLER';
            $order->{buyer}           = $order->{client_loginid};
            $order->{seller}          = $order->{advertiser_loginid};
        } else {
            $order->{client_role}     = 'SELLER';
            $order->{advertiser_role} = 'BUYER';
            $order->{buyer}           = $order->{advertiser_loginid};
            $order->{seller}          = $order->{client_loginid};
        }
        $order->{disputer_loginid} //= '[none]';
        $order->{dispute_reason} = $dispute_reasons{$order->{dispute_reason} // ''} // '[no predefined reason]';
        $order->{disputer_role}  = '[not under dispute]';
        $order->{disputer_role}  = $order->{client_role}
            if $order->{disputer_loginid} eq $order->{client_loginid};
        $order->{disputer_role} = $order->{advertiser_role}
            if $order->{disputer_loginid} eq $order->{advertiser_loginid};
        $order->{client_id}   //= '[not an advertiser]';
        $order->{client_name} //= '[not an advertiser]';
        $order->{$_} = format_time(Date::Utility->new($order->{$_}), $tz_offset) for qw( created_time expire_time );
        ($order->{$_} = $order->{$_} ? 'Yes' : 'No') for qw( client_confirmed advertiser_confirmed );
        $order->{$_}             = ucfirst($order->{$_}) for qw( type status advert_type);
        $order->{amount_display} = financialrounding('amount', $order->{account_currency}, $order->{amount});
        $order->{price_display}  = financialrounding('amount', $order->{local_currency},   $order->{rate} * $order->{amount});
        $order->{$_}             = sprintf('%.6f', $order->{$_}) + 0 for qw(rate advert_rate);
        $order->{escrow}         = get_escrow($broker, $order->{account_currency});

        my $client = BOM::User::Client->new({
            loginid      => $order->{client_loginid},
            db_operation => 'backoffice_replica'
        });
        my $pm_defs = $client->p2p_payment_methods();
        my $json    = JSON::MaybeXS->new;

        my $methods =
            lc $order->{type} eq 'buy'
            ? $client->_p2p_advertiser_payment_methods(
            advert_id  => $order->{advert_id},
            is_enabled => 1
            )
            : $client->_p2p_advertiser_payment_methods(
            order_id   => $order->{id},
            is_enabled => 1
            );

        $order->{payment_method_details}      = $client->_p2p_advertiser_payment_method_details($methods) if %$methods;
        $order->{advert_payment_method_names} = join ', ',
            sort map { $pm_defs->{$_}{display_name} } ($order->{advert_payment_method_names} // [])->@*;

        my $transaction_history = $db->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM p2p.order_transaction_history(?)', {Slice => {}}, $id);
            });

        my %history_by_ts;
        for my $row (@$transaction_history) {
            $row->{src_loginid}               = $order->{TRANSACTION_MAPPER->{$row->{type}}->{src_loginid}};
            $row->{dest_loginid}              = $order->{TRANSACTION_MAPPER->{$row->{type}}->{dest_loginid}};
            $row->{du}                        = Date::Utility->new($row->{transaction_time});
            $history_by_ts{$row->{du}->epoch} = $row;
        }

        my $status_history = $client->p2p_order_status_history($order->{id});

        for my $row (@$status_history) {
            my $du = Date::Utility->new($row->{stamp});
            # match the status with transaction when epoch matches
            $history_by_ts{$du->epoch}->@{qw(status du)} = ($row->{status}, $du);
        }

        for my $ts (sort keys %history_by_ts) {
            my $item = $history_by_ts{$ts};
            $item->{stamp} = format_time($item->{du}, $tz_offset);
            push @transactions, $item;
        }

        if (my $items = BOM::Config::Redis->redis_p2p->lrange("P2P::VERIFICATION_HISTORY::$id", 0, -1)) {
            for my $item (@$items) {
                my ($ts, $event) = split /\|/, $item;
                push @verification_history,
                    {
                    datetime => format_time(Date::Utility->new($ts), $tz_offset),
                    event    => $event
                    };
            }
        }

        $history = $db->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM p2p.order_advert_history(?)', {Slice => {}}, $id);
            });

        for my $row (@$history) {
            if ($row->{payment_method}) {
                my $def = $pm_defs->{$row->{payment_method}};
                $row->{method_name} = $def->{display_name};
                for my $field (grep { $row->{$_} } ('old', 'new')) {
                    my $pm = $json->decode($row->{$field});
                    for my $pm_field (keys $def->{fields}->%*) {
                        $row->{$field . '_fields'}{$def->{fields}{$pm_field}{display_name}} = $pm->{$pm_field} // '';
                    }
                }
            }

            if ($row->{change} eq 'Payment Method Names') {
                for my $field (grep { $row->{$_} } ('old', 'new')) {
                    $row->{$field} = join ', ', sort map { $pm_defs->{$_}{display_name} } split ',', $row->{$field};
                }
            }
        }

        my $buy_confirm_pms = $db->run(
            fixup => sub {
                $_->selectall_hashref('SELECT * FROM p2p.order_payment_methods_at_buy_confirm(?)', 'id', {Slice => {}}, $id);
            });

        if ($buy_confirm_pms) {
            $buy_confirm_pms->{$_}{fields} = $json->decode($buy_confirm_pms->{$_}{params}) for keys %$buy_confirm_pms;
            $order->{buy_confirm_pms} = $client->_p2p_advertiser_payment_method_details($buy_confirm_pms);
        }

        if ($order->{chat_channel_url}) {
            $chat_messages = $db_collector->run(
                fixup => sub {
                    $_->selectall_arrayref(
                        q{SELECT * FROM data_collection.p2p_chat_message_list(?,?,?)},
                        {Slice => {}},
                        $order->{chat_channel_url},
                        $chat_messages_limit, $chat_messages_limit * ($chat_page - 1));
                });
        }

        for my $country (uniq($order->{client_country}, $order->{advertiser_country}, BOM::Backoffice::Utility::get_office_countries())) {
            $timezones{$country} = DateTime::TimeZone->names_in_country($country);
        }

        @schedules{qw(client_orig advertiser_orig)} = $order->@{qw(client_schedule advertiser_schedule)};

        $schedules{client_current} = $db->run(
            fixup => sub {
                $_->selectrow_array('SELECT periods FROM p2p.get_advertiser_schedule(?)', undef, $order->{client_id});
            });
        delete $schedules{client_orig} if ($schedules{client_orig} // '') eq ($schedules{client_current} // '');

        $schedules{advertiser_current} = $db->run(
            fixup => sub {
                $_->selectrow_array('SELECT periods FROM p2p.get_advertiser_schedule(?)', undef, $order->{advertiser_id});
            });
        delete $schedules{advertiser_orig} if ($schedules{advertiser_orig} // '') eq ($schedules{advertiser_current} // '');

        if (grep { defined $_ } values %schedules) {
            try {
                for my $k (qw(client_orig advertiser_orig client_current advertiser_current)) {
                    $schedules{$k} = BOM::P2P::BOUtility::format_schedule($schedules{$k}, $tz_offset) if $schedules{$k};
                }

            } catch ($e) {
                $log->warnf('error processing advertiser schedules for order %s: %s', $order->{id}, $e);
                undef %schedules;
            }
        }
    } catch ($e) {
        print '<p class="error">' . $e . '</p>';
    }
}

# Resolve chat_user_id into client loginids and role
$chat_messages //= [];
$chat_messages = [map { prep_chat_message($_, $order, $tz_offset) } @$chat_messages];

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_order_manage.tt',
    {
        broker             => $broker,
        order              => $order,
        transactions       => \@transactions,
        history            => $history,
        chat_messages      => $chat_messages,
        chat_messages_next => scalar @{$chat_messages} < $chat_messages_limit
        ? undef
        : $chat_page + 1,    # When undef link won't be show
        chat_messages_prev => $chat_page > 1
        ? $chat_page - 1
        : undef,             # When undef link won't be show
        sendbird_token       => $sendbird_token,
        dispute_reasons      => \%dispute_reasons,
        can_dispute          => $can_dispute,
        verification_history => \@verification_history,
        timezones            => \%timezones,
        schedules            => \%schedules,
        timezone_offset      => sprintf('%+d', $tz_offset / 3600),
    });

code_exit_BO();

=head2 prep_chat_message

Resolves the chat user and role to display on UI.
The chat_user_id value will be used as last resort, when no clientid is reached.
The string 'other' will be role's last resort.

=over 4

=item C<$chat> a hashref for the chat message being parsed
=item C<$order> the current p2p order

=back

Returns, 
    The C<$chat> hashref properly parsed

=cut

sub prep_chat_message {
    my ($chat, $order, $tz_offset) = @_;

    $chat->{created_time} = format_time(Date::Utility->new($chat->{created_time}), $tz_offset);
    $chat->{chat_user}    = $chat->{chat_user_id};
    $chat->{chat_role}    = 'other';
    $chat->{chat_user}    = $order->{client_loginid}
        if $order->{client_chat_user_id} eq $chat->{chat_user_id};
    $chat->{chat_user} = $order->{advertiser_loginid}
        if $order->{advertiser_chat_user_id} eq $chat->{chat_user_id};
    $chat->{chat_role} = $order->{client_role}
        if $order->{client_chat_user_id} eq $chat->{chat_user_id};
    $chat->{chat_role} = $order->{advertiser_role}
        if $order->{advertiser_chat_user_id} eq $chat->{chat_user_id};

    return $chat;
}

sub get_escrow {
    my ($broker, $currency) = @_;
    my @escrow_list = BOM::Config::Runtime->instance->app_config->payments->p2p->escrow->@*;
    foreach my $loginid (@escrow_list) {
        my $c = BOM::User::Client->new({loginid => $loginid});
        return $c->loginid
            if $c->broker eq $broker && $c->currency eq $currency;
    }
}

sub format_time {
    my ($du, $offset) = @_;
    $du = $du->plus_time_interval($offset . 's') if $offset;
    return $du->datetime . ' (' . $du->full_day_name . ')';
}
