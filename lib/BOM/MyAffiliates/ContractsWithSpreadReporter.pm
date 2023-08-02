package BOM::MyAffiliates::ContractsWithSpreadReporter;

=head1 NAME

BOM::MyAffiliates::ContractsWithSpreadReporter

=head1 DESCRIPTION

This class generates clients' trading commission reports for contracts with spread. 

When buy transaction is carried out, ask_spread which is the commission charged on buy is inserted into the child table.

When sell transaction is carried out, bid_spread which is the commission charged on sell is inserted into the child table.

Sell commission is only considered when the contract is not yet expired. 

The total commission on contract is then calculated as = ask_spread + bid_spread(only if during the sell process contract is not expired). 

Total Affiliate commission is a percentage of total contract commission. This value is different for financial and non_financial underlyings
and is set in BackOffice. 

=head1 SYNOPSIS

    use BOM::MyAffiliates::ContractsWithSpreadReporter;

    my $reporter = BOM::MyAffiliates::ContractsWithSpreadReporter->new(
        brand             => Brands->new(),
        processing_date   => Date::Utility->new('18-Aug-10'));
        contract_category => 'turbos'  # turbos is an example of a with spread commission contract

    $reporter->activity();

=cut

use Moose;
extends 'BOM::MyAffiliates::Reporter';

use Text::CSV;
use Date::Utility;
use Format::Util::Numbers            qw(financialrounding);
use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::Config::Runtime;

=head2 HEADERS

defining headers to be used in the csv file

=cut

use constant HEADERS => qw(
    date client_loginid trade_commission commission exchange_rate
);

=head2 include_headers

Including headers.

=cut

has '+include_headers' => (
    default => 1,
);

=head2 contract_category

The contract category which affiliate report is generated for

=cut

has contract_category => (
    is => 'ro',
);

=head2 activity

    $reporter->activity();

    Produce a nicely formatted CSV output adjusted to USD.

=cut

sub activity {
    my $self = shift;

    my $when = $self->processing_date;

    my $result = $self->computation();

    my $apps_by_brand = $self->get_apps_by_brand();

    my $activity = $self->database_mapper()->get_clients_activity({
        date              => $when->date_yyyymmdd,
        only_authenticate => 'false',
        broker_code       => undef,
        include_apps      => $apps_by_brand->{include_apps},
        exclude_apps      => $apps_by_brand->{exclude_apps},
    });

    my @output          = ();
    my %conversion_hash = ();

    push @output, $self->format_data($self->headers_data()) if ($self->include_headers and keys %{$result});

    foreach my $loginid (sort keys %{$result}) {
        next if $self->is_broker_code_excluded($loginid);

        my $currency = $activity->{$loginid}->{currency};

        # this is for optimization else we would need to call in_usd for each record
        # this only calls if currency is not in hash
        $conversion_hash{$currency} = in_usd(1, $currency) unless exists $conversion_hash{$currency};

        my $csv           = Text::CSV->new;
        my @output_fields = (
            $when->date_yyyymmdd,
            $self->prefix_field($loginid),
            financialrounding('amount', 'USD', $result->{$loginid}->{trade_commission} * $conversion_hash{$currency}),
            financialrounding('amount', 'USD', $result->{$loginid}->{commission} * $conversion_hash{$currency}));

        if ($currency eq 'USD') {
            push @output_fields, financialrounding('amount', 'USD', 1);
        } else {
            # we need to convert other currencies to USD as required
            # by myaffiliates system
            push @output_fields, financialrounding('amount', 'USD', $conversion_hash{$currency});
        }

        $csv->combine(@output_fields);
        push @output, $self->format_data($csv->string);
    }

    return @output;
}

=head2 computation

    $reporter->computation();

    Calculates affiliate commission.

=cut

sub computation {
    my $self = shift;

    my $app_config    = BOM::Config::Runtime->instance->app_config;
    my $when          = $self->processing_date;
    my $apps_by_brand = $self->get_apps_by_brand();

    my $records = $self->database_mapper()->get_contracts_with_spread_commission({
        bet_class    => $self->contract_category,
        date         => $when->date_yyyymmdd,
        include_apps => $apps_by_brand->{include_apps},
        exclude_apps => $apps_by_brand->{exclude_apps},
    });

    my $result = {};
    my $commission_ratio;

    foreach my $info (@$records) {
        my $loginid          = @$info[0];
        my $currency         = @$info[1];
        my $market_type      = @$info[2];
        my $trade_commission = @$info[3];
        my $commission;

        if ($market_type eq "non_financial") {
            $commission_ratio = $app_config->get('quants.' . $self->contract_category . '.affiliate_commission.non_financial');
        } else {
            $commission_ratio = $app_config->get('quants.' . $self->contract_category . '.affiliate_commission.financial');
        }

        if (exists $result->{$loginid}) {
            $commission = $result->{$loginid}->{commission} + $trade_commission * $commission_ratio;
            $trade_commission += $result->{$loginid}->{trade_commission};
            $result->{$loginid} = {
                trade_commission => $trade_commission,
                commission       => $commission,
                currency         => $currency
            };
        } else {
            $result->{$loginid} = {
                trade_commission => $trade_commission,
                commission       => $trade_commission * $commission_ratio,
                currency         => $currency
            };
        }
    }

    return $result;
}

=head2 output_file_prefix

    $reporter->output_file_prefix;

    indicates the prefix for the output file. 

=cut

sub output_file_prefix {
    my $self = shift;

    return $self->contract_category . '_';
}

=head2 headers

    $reporter->headers;

    returns the list of headers. 

=cut

sub headers {
    return HEADERS;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
