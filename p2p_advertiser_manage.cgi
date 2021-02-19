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
use BOM::User::Client;
use BOM::User::Utility;
use BOM::Platform::Event::Emitter;
use BOM::Config::Runtime;
use Format::Util::Numbers qw(financialrounding);
use Syntax::Keyword::Try;
use Scalar::Util qw(looks_like_number);
use List::Util qw(min max);
use Data::Dumper;

my $cgi = CGI->new;

PrintContentType();
try { BrokerPresentation(' '); }
catch { }
Bar('P2P Advertiser Management');

my %input  = %{request()->params};
my $broker = request()->broker_code;
my %output;

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'write'
    })->db->dbic;

my $p2p_write = BOM::Backoffice::Auth0::has_authorisation(['P2PWrite']);

if ($input{create}) {
    try {
        my $client = BOM::User::Client->new({loginid => $input{new_loginid}});
        $client->p2p_advertiser_create(name => $input{new_name});
        $output{message} = $input{new_loginid} . ' has been registered as P2P advertiser.';
    } catch {
        my $err = $@;
        $Data::Dumper::Terse = 1;
        $output{error} = $input{new_loginid} . ' could not be registered as a P2P advertiser: ' . Dumper($err);
    }
}

if ($input{update}) {
    try {
        my $id   = $input{update_id};
        my $name = $input{update_name};

        my ($existing) = $db->run(
            fixup => sub {
                $_->selectrow_array('SELECT * FROM p2p.advertiser_list(NULL,NULL,NULL,?) WHERE id != ?', undef, $name, $id);
            });

        die "There is already another advertiser with this nickname\n" if $existing;
        die "You do not have permission to set band level\n"           if $input{trade_band} && !$p2p_write;

        $output{advertiser} = $db->run(
            fixup => sub {
                $_->selectrow_hashref(
                    'UPDATE p2p.p2p_advertiser SET name = ?, is_approved = ?, is_listed = ?, default_advert_description = ?, 
                        payment_info = ?, contact_info = ?, trade_band = COALESCE(?,trade_band), cc_sell_authorized = ?, show_name = ?
                        WHERE id = ? RETURNING *',
                    undef,
                    @input{
                        qw/update_name is_approved is_listed default_advert_description payment_info contact_info trade_band cc_sell_authorized show_name update_id/
                    });
            });
        die "Invalid advertiser ID\n" unless $output{advertiser};

        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $output{advertiser}->{client_loginid},
            },
        );

        if ($name ne $input{current_name}) {
            my $sendbird_api = BOM::User::Utility::sendbird_api();
            WebService::SendBird::User->new(
                user_id    => $output{advertiser}->{chat_user_id},
                api_client => $sendbird_api
            )->update(nickname => $name);
        }

        $output{message} = "Advertiser $id details saved.";
    } catch {
        my $err = $@;
        $Data::Dumper::Terse = 1;
        $output{error} = 'Could not update P2P advertiser: ' . Dumper($err);
    }
}

!$input{$_} && delete $input{$_} for qw(loginID name);
delete $input{id} unless looks_like_number($input{id});
$input{loginID} = trim uc $input{loginID} if $input{loginID};

if ($input{loginID} || $input{name} || $input{id}) {
    $output{advertiser} = $db->run(
        fixup => sub {
            $_->selectrow_hashref(
                'SELECT l.*, c.first_name, c.last_name FROM p2p.advertiser_list(?,?,NULL,?) l
            JOIN betonmarkets.client c ON c.loginid = l.client_loginid', undef, @input{qw/id loginID name/});
        });
    $output{error} //= 'Advertiser not found' unless $output{advertiser};
}

if ($output{advertiser}) {
    my $ads = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT *, date_trunc('seconds',created_time) created_time FROM p2p.advert_list(NULL, NULL, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, TRUE) ORDER BY id DESC",
                {Slice => {}},
                $output{advertiser}->{id});
        });
    # pagination
    my $page_size = 30;
    my $start     = $input{start} // 0;
    $output{prev}  = max(($start - $page_size), 0) if $start;
    $output{next}  = $start + $page_size           if @$ads > $start + $page_size;
    $output{range} = ($start + 1) . '-' . min(($start + $page_size), scalar @$ads) . ' of ' . (scalar @$ads);
    $output{ads}   = [splice(@$ads, $start, $page_size)];

    $output{audit} = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT *,date_trunc('seconds',stamp) ts FROM audit.p2p_advertiser WHERE id = ? ORDER BY stamp DESC",
                {Slice => {}},
                $output{advertiser}->{id});
        });

    my $bands = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT DISTINCT(trade_band) FROM p2p.p2p_country_trade_band b, betonmarkets.client c 
                    WHERE c.loginid = ? AND (b.country = c.residence OR b.country = 'default')",
                undef,
                $output{advertiser}->{client_loginid});
        });
    $output{bands} = [map { $_->[0] } @$bands];

    my $client = BOM::User::Client->new({loginid => $output{advertiser}->{client_loginid}});
    $output{p2p_balance}  = financialrounding('amount', $output{advertiser}->{account_currency}, $client->balance_for_cashier('p2p'));
    $output{sell_blocked} = $client->_p2p_validate_sell($client, $output{advertiser}) ? 'no' : 'yes';

} elsif ($input{loginID}) {
    try {
        local $SIG{__WARN__} = sub { };
        $output{client} = BOM::User::Client->new({loginid => $input{loginID}});
    } catch {
    }
    $output{error} = 'No such client: ' . $input{loginID} unless $output{client};
}

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_advertiser_manage.tt',
    {
        %output,
        p2p_write => $p2p_write,
    });

code_exit_BO();
