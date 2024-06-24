package BOM::Test::Helper::P2PWithClient;

use strict;
use warnings;

use BOM::Test::Helper::Client;
use BOM::User;
use P2P;
use BOM::Config;
use BOM::Rules::Engine;
use Carp;
use Test::More;
use Test::MockModule;
use Date::Utility;
use JSON::MaybeXS;

my $rule_engine = BOM::Rules::Engine->new();

my $advertiser_num = 1;
my $client_num     = 1;
my $mock_sb;
my $mock_sb_user;
my $mock_config;

{
    my ($current_escrow, $original_escrow);

    sub create_escrow {
        return $current_escrow if $current_escrow;

        $original_escrow = BOM::Config::Runtime->instance->app_config->payments->p2p->escrow;

        $current_escrow = BOM::Test::Helper::Client::create_client();
        $current_escrow->account('USD');

        BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([$current_escrow->loginid]);
        return $current_escrow;
    }

    sub reset_escrow {
        undef $current_escrow;
        BOM::Config::Runtime->instance->app_config->payments->p2p->escrow($original_escrow);
        return;
    }
}

sub create_advertiser {
    my %param = @_;

    $param{balance}     //= 0;
    $param{name}        //= 'test advertiser ' . (++$advertiser_num);
    $param{currency}    //= 'USD';
    $param{is_approved} //= 1;

    $param{client_details}{email} //= 'p2p_' . (++$client_num) . '@binary.com';

    my $user = BOM::User->create(
        email    => $param{client_details}{email},
        password => 'test'
    );

    $param{client_details}{binary_user_id} = $user->id;
    my $client = BOM::Test::Helper::Client::create_client(undef, undef, $param{client_details});

    $user->add_client($client);

    $client->account($param{currency});

    if ($param{balance}) {
        BOM::Test::Helper::Client::top_up($client, $client->currency, $param{balance});
    }

    $client->p2p_advertiser_create(name => $param{name});
    $client->p2p_advertiser_update(is_approved => $param{is_approved});
    delete $client->{_p2p_advertiser_cached};

    return $client;
}

sub create_advert {
    my %param = @_;

    $param{amount}           //= 100;
    $param{description}      //= 'Test advert';
    $param{type}             //= 'sell';
    $param{rate}             //= 1;
    $param{rate_type}        //= 'fixed';
    $param{min_order_amount} //= 0.1;
    $param{max_order_amount} //= 100;
    $param{payment_method}   //= 'bank_transfer' unless ($param{payment_method_ids} or $param{payment_method_names});

    $param{payment_info} //= $param{type} eq 'sell' ? 'Bank: 123456' : undef;
    $param{contact_info} //= $param{type} eq 'sell' ? 'Tel: 123456'  : undef;

    my $advertiser = $param{client} // create_advertiser(
        balance        => $param{type} eq 'sell' ? $param{amount} : 0,
        client_details => $param{advertiser},
    );
    delete $advertiser->{_p2p_advertiser_cached};

    my $advert = P2P->new(client => $advertiser)->p2p_advert_create(%param);

    return $advertiser, $advert;
}

sub create_order {
    my %param = @_;

    my $advert_id = $param{advert_id} || croak 'advert_id is required';
    my $amount    = $param{amount}  // 100;
    my $balance   = $param{balance} // $param{amount};
    my $client    = $param{client}  // create_advertiser(
        balance        => $balance,
        client_details => $param{advertiser});
    delete $client->{_p2p_advertiser_cached};

    my $advert = $client->p2p_advert_info(id => $param{advert_id});

    $param{payment_info} //= $advert->{type} eq 'buy' ? 'Bank: 123456' : undef;
    $param{contact_info} //= $advert->{type} eq 'buy' ? 'Tel: 123456'  : undef;

    my $order = $client->p2p_order_create(
        advert_id    => $advert_id,
        amount       => $amount,
        payment_info => $param{payment_info},
        contact_info => $param{contact_info},
        rule_engine  => $rule_engine,
    );

    # NOW() in db will not be affected when we mock time in tests, so we need to adjust order creation time
    if (time != CORE::time) {
        $client->db->dbic->dbh->do('UPDATE p2p.p2p_order SET created_time = ? WHERE id =?', undef, Date::Utility->new->datetime, $order->{id});
    }

    return $client, $order;
}

sub expire_order {
    my ($client, $order_id, $interval) = @_;
    $interval //= '-1 day';
    $interval = $client->db->dbic->dbh->quote($interval);
    return $client->db->dbic->dbh->do(
        "UPDATE p2p.p2p_order SET expire_time = NOW() + INTERVAL $interval WHERE id = ?",    ## SQL safe($interval)
        undef, $order_id
    );
}

sub ready_to_refund {
    my ($client, $order_id, $days_needed) = @_;
    $days_needed //= BOM::Config::Runtime->instance->app_config->payments->p2p->refund_timeout;

    return $client->db->dbic->dbh->do(
        "UPDATE p2p.p2p_order SET status='timed-out', expire_time = ?::TIMESTAMP - INTERVAL ? WHERE id = ?",
        undef,
        Date::Utility->new->datetime,
        sprintf('%d days', $days_needed), $order_id
    );
}

=head2 populate_trade_band_db

medium and high band are present in  cr01 production DB but not populated in QA box. Hence, this function will
add entries in p2p.p2p_country_trade_band for these two bands along with their respective band criteria. 
we will reduce min_completed_orders to 3 for both medium and high bands for the sake of testing.

=cut

sub populate_trade_band_db {
    my $client = BOM::Test::Helper::Client::create_client();

    $client->db->dbic->dbh->do(
        "INSERT INTO p2p.p2p_country_trade_band 
               (trade_band, country, currency, max_daily_buy, max_daily_sell, min_joined_days, max_allowed_dispute_rate,
                min_completion_rate, min_completed_orders, max_allowed_fraud_cases, poa_required, email_alert_required, automatic_approve,
                min_order_amount, max_order_amount, block_trade_min_order_amount, block_trade_max_order_amount)
         VALUES 
               ('medium', 'default', 'USD', 5000, 2000, 90, 0.02, 0.94, 3, 0, TRUE, FALSE, TRUE, NULL, NULL, NULL, NULL),
               ('high', 'default', 'USD', 10000, 10000, 180, 0, 0.98, 3, 0, TRUE, TRUE, FALSE, NULL, NULL, NULL, NULL),
               ('block_trade_medium', 'default', 'USD', 20000, 20000, 365, NULL, NULL, NULL, NULL, FALSE, TRUE, FALSE, 5, 500, 1000, 10000),
               ('block_trade_high', 'default', 'USD', 50000, 50000, 730, NULL, NULL, NULL, NULL, FALSE, TRUE, FALSE, 5, 500, 1000, 20000)"
    );

    return 1;
}

=head2 set_advertiser_created_time_by_day

Modify created_time of a particular advertiser in p2p.p2p_advertiser table

Example usage:
    set_advertiser_created_time_by_day($advertiser, -92); --> set advertiser created_time to 92 days before current date.
    set_advertiser_created_time_by_day($advertiser, 30); --> set advertiser created_time to 30 days after current date.
Takes the following arguments:

=over 4

=item * C<advertiser> - P2P advertiser client object

=item * C<day> - if value > 0, set created_time to $day days after current date, if value < 0, set created_time to $day days before current date

=cut

sub set_advertiser_created_time_by_day {
    my ($advertiser, $day) = @_;
    my $day_str = $advertiser->db->dbic->dbh->quote(abs($day) . ' day');
    my $time    = $day < 0 ? ("NOW() - interval $day_str") : ("NOW() + interval $day_str");
    my $sql     = "update p2p.p2p_advertiser set created_time = $time WHERE client_loginid = ?";    ## SQL safe($time)
    $advertiser->db->dbic->dbh->do($sql, undef, $advertiser->loginid);
    return 1;
}

=head2 set_advertiser_completion_rate
Sets advertiser completion rate to a value of 0-1 or undef
=cut

sub set_advertiser_completion_rate {
    my ($advertiser, $rate) = @_;

    my ($total, $success) = defined $rate ? (1000, sprintf('%.0f', 1000 * $rate)) : (undef, undef);

    $advertiser->db->dbic->dbh->do(
        'INSERT INTO p2p.p2p_advertiser_totals (advertiser_id, complete_total, complete_success) VALUES (?,?,?) 
        ON CONFLICT (advertiser_id) DO UPDATE SET complete_total = EXCLUDED.complete_total, complete_success = EXCLUDED.complete_success',
        undef, $advertiser->_p2p_advertiser_cached->{id}, $total, $success
    );

    delete $advertiser->{_p2p_advertiser_cached};

    return 1;
}

=head2 set_advertiser_rating_average
Sets advertiser rating average to a value of 1-5 or undef
=cut

sub set_advertiser_rating_average {
    my ($advertiser, $average) = @_;

    $advertiser->db->dbic->dbh->do(
        'INSERT INTO p2p.p2p_advertiser_totals (advertiser_id, rating_average) VALUES (?,?) 
        ON CONFLICT (advertiser_id) DO UPDATE SET rating_average = EXCLUDED.rating_average',
        undef, $advertiser->_p2p_advertiser_cached->{id}, $average
    );

    delete $advertiser->{_p2p_advertiser_cached};

    return 1;
}

sub set_order_status {
    my ($client, $order_id, $new_status) = @_;

    $client->db->dbic->dbh->do(
        "UPDATE p2p.p2p_advert a SET active_orders=active_orders+
        CASE 
            WHEN p2p.is_status_final(?) AND NOT p2p.is_status_final(o.status) THEN -1
            WHEN NOT p2p.is_status_final(?) AND p2p.is_status_final(o.status) THEN 1
            ELSE 0
        END
        FROM p2p.p2p_order o WHERE o.advert_id = a.id AND o.id = ?",
        undef, $new_status, $new_status, $order_id
    );

    $client->db->dbic->dbh->do('SELECT * FROM p2p.order_update(?, ?, NULL)', undef, $order_id, $new_status);
}

sub bypass_sendbird {
    $mock_sb      = Test::MockModule->new('WebService::SendBird');
    $mock_sb_user = Test::MockModule->new('WebService::SendBird::User');

    $mock_sb->mock(
        'create_user',
        sub {
            note "mocking sendbird create_user";
            return WebService::SendBird::User->new(
                api_client     => 1,
                user_id        => 'dummy',
                session_tokens => [{
                        'session_token' => 'dummy',
                        'expires_at'    => (time + 7200) * 1000,
                    }]);
        });

    $mock_sb->mock(
        'create_group_chat',
        sub {
            note "mocking sendbird create_group_chat";
            return WebService::SendBird::GroupChat->new(
                api_client  => 1,
                channel_url => 'dummy',
            );
        });

    $mock_sb_user->mock(
        'issue_session_token',
        sub {
            note "mocking sendbird issue_session_token";
            return {
                'session_token' => 'dummy',
                'expires_at'    => (time + 7200) * 1000,
            };
        });
}

=head2 set_order_disputable

Given a p2p order, it updates any requirement needed to be ready for dispute.

=cut

sub set_order_disputable {
    my ($client, $order_id) = @_;

    expire_order($client, $order_id);

    # Status needs to be `timed-out`
    $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM p2p.order_update(?, ?, NULL)', undef, $order_id, 'timed-out');
        });
}

=head2 create_payment_methods

Creates dummy payment method definitions that advertisers can create with p2p_advertiser_payment_methods().
Method ids will be method1 - method10.

=cut

sub create_payment_methods {

    my $methods;
    for my $i (1 .. 10) {
        $methods->{"method$i"} = {
            display_name => "Method $i",
            type         => 'ewallet',
            fields       => {
                tag => {
                    display_name => 'ID',
                    required     => 0
                }
            },
        };
    }

    $mock_config = Test::MockModule->new('BOM::Config');
    $mock_config->mock('p2p_payment_methods' => $methods);

    my %country_config = map { $_ => {mode => 'exclude'} } keys %$methods;
    my $json           = JSON::MaybeXS->new->encode(\%country_config);
    BOM::Config::Runtime->instance->app_config->payments->p2p->payment_method_countries($json);
}

=head2 set_advertiser_is_enabled

Permanently block or unblock P2P advertiser

Example usage:

    set_advertiser_is_enabled($advertiser, 0); --> disable advertiser
    set_advertiser_is_enabled($advertiser, 1); --> enable advertiser

Takes the following arguments:

=over 4

=item * C<advertiser> - P2P advertiser client object

=item * C<is_enabled> - flag to indicate whether to enable or disable advertiser

=cut

sub set_advertiser_is_enabled {
    my ($advertiser, $is_enabled) = @_;
    my $sql = "update p2p.p2p_advertiser set is_enabled=" . ($is_enabled ? 'TRUE' : 'FALSE') . " WHERE client_loginid = ?";
    $advertiser->db->dbic->dbh->do($sql, undef, $advertiser->loginid);
    return 1;
}

=head2 set_advertiser_blocked_until

Temporarily block P2P advertiser or remove temporary block of advertiser

Example usage:

    set_advertiser_blocked_until($advertiser, 2); --> temporarily block advertiser for another 2 hours
    set_advertiser_blocked_until($advertiser, 0); --> remove temporary block of advertiser

Takes the following arguments:

=over 4

=item * C<advertiser> - P2P advertiser client object

=item * C<temp_blocked_hours> - if value >= 1, block for that many hours, if value = 0, remove temporary block

=cut

sub set_advertiser_blocked_until {
    my ($advertiser, $temp_blocked_hours) = @_;
    carp "temp_blocked_hours must be a positive integer" if defined($temp_blocked_hours) && $temp_blocked_hours !~ /^\d+$/;
    $temp_blocked_hours = $temp_blocked_hours ? "NOW() + INTERVAL '" . $temp_blocked_hours . " hour'" : "NULL";
    my $sql = "update p2p.p2p_advertiser set blocked_until=$temp_blocked_hours WHERE client_loginid = ?";    ## SQL safe($temp_blocked_hours)
    $advertiser->db->dbic->dbh->do($sql, undef, $advertiser->loginid);
    return 1;
}

1;
