#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use BOM::Database::ClientDB;
use Syntax::Keyword::Try;
use Date::Utility;
use BOM::Config::Runtime;
use BOM::Config;
use Scalar::Util qw(looks_like_number);
use BOM::Platform::Event::Emitter;

my $cgi = CGI->new;

PrintContentType();
BrokerPresentation(' ');

my $p2p_write      = BOM::Backoffice::Auth0::has_authorisation(['P2PWrite']);
my $config         = BOM::Config::third_party();
my $sendbird_token = $config->{sendbird}->{api_token};

my %input  = %{request()->params};
my $broker = request()->broker_code;

my %dispute_reasons = (
    seller_not_released => 'Seller did not release funds',
    buyer_overpaid      => 'Buyer paid too much',
    buyer_underpaid     => 'Buyer paid less',
    buyer_not_paid      => 'Buyer has not made any payment',
);

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'write'
    })->db->dbic;

my $db_collector = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
    })->db->dbic;

my ($order, $escrow, $transactions, $chat_messages);
my $chat_messages_limit = 20;
my $chat_page           = int($input{p} // 1);
$chat_page = 1
    unless $chat_page > 0;    # The default page is 1 so math is well adjusted

Bar('P2P Order details/management');

if ($input{action} and $p2p_write) {
    try {
        my $client = BOM::User::Client->new({loginid => $input{disputer}});
        $client->p2p_resolve_order_dispute(
            id     => $input{order_id},
            action => $input{action},
            fraud  => $input{fraud},
            staff  => BOM::Backoffice::Auth0::get_staffname(),
        );
    } catch ($e) {
        my $error = ref $e eq 'ARRAY' ? join ', ', $e->@* : $e;
        print '<p class="error">' . $error . '</p>';
    }
}

if ($input{dispute} and $p2p_write) {
    try {
        die "Invalid dispute reason.\n" unless exists $dispute_reasons{$input{reason}};

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
        die "Invalid id - $id\n" unless looks_like_number($id) and $id > 0;
        $order = $db->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM p2p.order_list(?,NULL,NULL,NULL)', undef, $id);
            });
        die "Order $id not found\n" unless $order;
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
        $order->{$_} = Date::Utility->new($order->{$_})->datetime_ddmmmyy_hhmmss for qw( created_time expire_time );
        ($order->{$_} = $order->{$_} ? 'Yes' : 'No') for qw( client_confirmed advertiser_confirmed );
        $order->{$_} = ucfirst($order->{$_}) for qw( type status );
        $order->{payment_due} = $order->{amount} * $order->{advert_rate};
        $escrow = get_escrow($broker, $order->{account_currency});

        $transactions = $db->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT pt.transaction_time, pt.type, 
                        tf.id src_id, af.client_loginid src_loginid, tf.amount src_amount, tf.staff_loginid src_staff, tf.action_type src_action_type, tf.payment_id src_payment_id,
                        tt.id dest_id, at.client_loginid dest_loginid, tt.amount dest_amount, tt.staff_loginid dest_staff, tt.action_type dest_action_type, tt.payment_id dest_payment_id
                    FROM p2p.p2p_transaction pt 
                        JOIN transaction.transaction tf ON tf.id = pt.from_transaction_id
                        JOIN transaction.account af ON af.id = tf.account_id 
                        JOIN transaction.transaction tt ON tt.id = pt.to_transaction_id
                        JOIN transaction.account at ON at.id = tt.account_id 
                        WHERE pt.order_id = ?
                        ORDER BY pt.transaction_time',
                    {Slice => {}}, $id
                );
            });

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
    } catch ($e) {
        print '<p class="error">' . $e . '</p>';
    }
}

# Resolve chat_user_id into client loginids and role
$chat_messages //= [];
$chat_messages = [map { prep_chat_message($_, $order) } @{$chat_messages}];

if ($order) {
    my $order_client    = BOM::User::Client->new({loginid => $order->{client_loginid}});
    my $status_history  = $order_client->p2p_order_status_history($order->{id});
    my $status_by_stamp = +{map { Date::Utility->new($_->{stamp})->datetime_yyyymmdd_hhmmss => $_->{status} } reverse $status_history->@*};
    my $status_bag      = +{map { $_->{status} => Date::Utility->new($_->{stamp})->datetime_yyyymmdd_hhmmss } $status_history->@*};

    # We try to pair a transaction with its correspondent status by timestamp
    foreach ($transactions->@*) {
        my $stamp = Date::Utility->new($_->{transaction_time})->datetime_yyyymmdd_hhmmss;

        if (defined $status_by_stamp->{$stamp}) {
            $_->{status} = $status_by_stamp->{$stamp};
            delete $status_bag->{$_->{status}};
        }
    }

    # If a status is not matching a transaction, just push it and generate an empty tx row
    push @$transactions, (map { +{status => $_, transaction_time => $status_bag->{$_}} } keys %$status_bag);
    # Finally, sort by timestamp
    $transactions =
        [sort { Date::Utility->new($a->{transaction_time})->epoch cmp Date::Utility->new($b->{transaction_time})->epoch } $transactions->@*];
}

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_order_manage.tt',
    {
        broker             => $broker,
        order              => $order,
        escrow             => $escrow,
        transactions       => $transactions,
        p2p_write          => $p2p_write,
        chat_messages      => $chat_messages,
        chat_messages_next => scalar @{$chat_messages} < $chat_messages_limit
        ? undef
        : $chat_page + 1,    # When undef link won't be show
        chat_messages_prev => $chat_page > 1
        ? $chat_page - 1
        : undef,             # When undef link won't be show
        sendbird_token  => $sendbird_token,
        dispute_reasons => \%dispute_reasons,
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
    my ($chat, $order) = @_;
    $chat->{chat_user} = $chat->{chat_user_id};
    $chat->{chat_role} = 'other';
    $chat->{chat_user} = $order->{client_loginid}
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
