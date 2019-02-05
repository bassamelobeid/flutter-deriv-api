package BOM::MarketDataAutoUpdater::InterestRates;

use Moose;
extends 'BOM::MarketDataAutoUpdater';

use List::MoreUtils qw(notall);
use Scalar::Util qw(looks_like_number);
use Text::CSV::Slurp;

use Bloomberg::FileDownloader;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use Date::Utility;
use Format::Util::Numbers qw(roundcommon);
use Bloomberg::CurrencyConfig;
use Quant::Framework::InterestRate;

has file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_file {
    my @files = Bloomberg::FileDownloader->new->grab_files({file_type => 'interest_rate'});
    return $files[0];
}

sub run {
    my $self = shift;

    my $file   = $self->file;
    my $csv    = Text::CSV::Slurp->load(file => $file);
    my $report = $self->report;

    my $rates;
    foreach my $line (@$csv) {
        my $item = $line->{SECURITIES};
        next if $item eq 'N.A.';
        my $item_rates = $line->{PX_LAST};
        my $error_code = $line->{'ERROR CODE'};

        if ($item_rates eq 'N.A.' or not looks_like_number($item_rates) or $error_code != 0) {
            push @{$report->{error}},
                'rates[' . $item_rates . '] provided by Bloomberg for security[' . $item . '] with error code [' . $error_code . ']';
            next;
        }

        if (my $data = $self->_get_currency_and_term_from_BB_ticker($item)) {
            $rates->{$data->{currency}}->{rates}->{$self->_tenor_mapper->{$data->{term}}} = roundcommon(0.001, $item_rates);
        } else {
            push @{$report->{error}}, "Unrecognized Bloomberg ticker[$item]";
            next;
        }
    }

    # we need to include rates for BTC LTC ETH ETC here. Currently setting it to zero rates.
    $rates->{$_}->{rates} = {
        0   => 0,
        365 => 0
    } foreach qw/BTC BCH LTC ETH ETC/;

    foreach my $currency_symbol (keys %$rates) {
        my $data = $rates->{$currency_symbol}->{rates};
        if (my $validation_error = $self->_passes_sanity_check($data, $currency_symbol)) {
            $report->{$currency_symbol} = {
                success => 0,
                reason  => $validation_error,
            };
        } else {
            my $rates = Quant::Framework::InterestRate->new(
                symbol           => $currency_symbol,
                rates            => $data,
                recorded_date    => Date::Utility->new,
                chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
            );
            $rates->save;
            $report->{$currency_symbol}->{success} = 1;
            $self->_update_related_currency($data, qw(UST USB)) if $currency_symbol eq 'USD';
        }
    }

    $self->SUPER::run();
    return 1;
}

sub _passes_sanity_check {
    my ($self, $data, $symbol) = @_;

    my @iv_symbols = create_underlying_db->get_symbols_for(
        market            => 'forex, commodities',
        contract_category => 'IV',
    );
    my $offers_iv = grep { $symbol =~ /$_/ } @iv_symbols;
    my $required_iv_terms = notall { defined $data->{$_} } qw(30 90 180);
    my $error_message =
        ($offers_iv and $required_iv_terms) ? 'We offer iv contracts for' . $symbol . ', but we don\'t have interest rates data for 1M, 3M & 6M' : '';

    return $error_message;
}

sub _get_currency_and_term_from_BB_ticker {
    my ($self, $ticker) = @_;
    my %tickerlist = Bloomberg::CurrencyConfig::get_interest_rate_list();

    foreach my $currency (keys %tickerlist) {
        foreach my $term (keys %{$tickerlist{$currency}}) {
            if ($ticker eq $tickerlist{$currency}{$term}) {
                return {
                    currency => $currency,
                    term     => $term
                };
            }
        }
    }

    return;
}

# update related currency interest rates currently we have UST/USD
# we might have USB/USD in the future
sub _update_related_currency {
    my ($self, $data, @related_currency) = @_;
    foreach (@related_currency) {
        my $rates = Quant::Framework::InterestRate->new(
            symbol           => $_,
            rates            => $data,
            recorded_date    => Date::Utility->new,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        $rates->save;
        $self->report->{$_}->{success} = 1;
    }
    return;
}

## In fact, the tenor mapping should not be fix, they have a specific convention to determine them.
## Example: For Libor, it should be following the rules as stated on this link,
## http://www.bbalibor.com/techinical-aspects/fixing-value-and-maturity
## However, we are not only getting from Libor, for HKD, it is from HIBOR; for AUD, it is from SWAP curve,
## it is too much work to clarify it, hence we decide to leave it as it is for now
## TODO: Get proper tenor mapping convention

has _tenor_mapper => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            'ON'  => 1,
            '1W'  => 7,
            '2W'  => 14,
            '1M'  => 30,
            '2M'  => 60,
            '3M'  => 90,
            '4M'  => 120,
            '5M'  => 150,
            '6M'  => 180,
            '7M'  => 210,
            '8M'  => 240,
            '9M'  => 270,
            '10M' => 300,
            '11M' => 330,
            '1Y'  => 365,
        };
    },
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
