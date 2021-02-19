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
use Scalar::Util qw(looks_like_number);

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
my @countries = map { {code => $_, name => $countries_list{$_}{name}} }
    sort { $countries_list{$a}{name} cmp $countries_list{$b}{name} } keys %countries_list;

my @currencies = sort @{request()->available_currencies};

if ($input{edit}) {
    Bar('Save band');
    try {
        for (qw(max_daily_buy max_daily_sell)) {
            die "invalid value for $_\n" unless (looks_like_number($input{$_}) && $input{$_} > 0);
        }

        $db->run(
            fixup => sub {
                $_->do(
                    "UPDATE p2p.p2p_country_trade_band SET max_daily_buy = ?, max_daily_sell =? WHERE country = ? AND trade_band = LOWER(?) AND currency = ?",
                    undef, @input{qw/max_daily_buy max_daily_sell country trade_band currency/});
            });
        print '<p class="success">Band configuration updated</p>';
    } catch {
        print '<p class="error">Failed to save band:' . $@ . '</p>';
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
    } catch {
        print '<p class="error">Failed to delete band:' . $@ . '</p>';
    }
    delete @input{qw/country trade_band currency max_daily_buy max_daily_sell action/};
    $action = 'new';
}

if ($input{save} or $input{copy}) {
    Bar('Save new band');
    my @fields = qw/country trade_band currency max_daily_buy max_daily_sell/;

    try {
        die "$_ is required\n" for grep { !$input{$_} } @fields;

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

        for (qw(max_daily_buy max_daily_sell)) {
            die "invalid value for $_\n" unless (looks_like_number($input{$_}) && $input{$_} > 0);
        }

        $db->run(
            fixup => sub {
                $_->do(
                    "INSERT INTO p2p.p2p_country_trade_band (country, trade_band, currency, max_daily_buy, max_daily_sell) VALUES (?,LOWER(?),?,?,?)",
                    undef, @input{@fields});
            });
        print '<p class="success">New band configuration saved</p>';
    } catch {
        print '<p class="error">Failed to save band: ' . $@ . '</p>';
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
