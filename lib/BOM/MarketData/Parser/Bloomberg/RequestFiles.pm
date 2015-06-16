package BOM::MarketData::Parser::Bloomberg::RequestFiles;

=head1 NAME

BOM::MarketData::Parser::Bloomberg::RequestFiles

=head1 DESCRIPTION

Generates the content of the various ".req" request files we need to
upload to BBDL's FTP server in order to tell the BBDL service what
kind of information to generate for us.

=cut

use strict;
use warnings;

use Moose;
use File::Slurp;
use File::Basename qw( dirname );
use Template;
use BOM::Utility::Log4perl qw( get_logger );

use BOM::Market::Types;
use BOM::Platform::Runtime;
use Date::Utility;
use BOM::Market::UnderlyingDB;
use BOM::Market::Underlying;
use BOM::MarketData::CurrencyConfig;
use BOM::MarketData::ExchangeConfig;

has _template => (
    is         => 'ro',
    isa        => 'Template',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build__template {
    my $self = shift;

    return Template->new({
            INCLUDE_PATH => dirname(__FILE__) . '/templates',
            INTERPOLATE  => 1,
            TRIM         => 1,
        }) || die $Template::ERROR;
}

=head1 OBJECT METHODS

=cut

# This is just a little wrapper around TT's slightly unintuitive (IMO) interface.
sub _process {
    my ($self, $name, $args) = @_;

    my $content;
    $self->_template->process($name . '.html.tt', $args, \$content) || die $Template::ERROR;

    return $content;
}

=head2 request_files_dir

The directory in which the request files are stored

=cut

has request_files_dir => (
    is      => 'ro',
    isa     => 'Str',
    default => sub { BOM::Platform::Runtime->instance->app_config->system->directory->tmp_gif },
);

=head2 volatility_source

The volatility source we are receiving from Bloomberg

=cut

has volatility_source => (
    is         => 'ro',
    isa        => 'bom_volatility_source',
    lazy_build => 1,
);

sub _build_volatility_source {
    return BOM::Platform::Runtime->instance->app_config->quants->market_data->volatility_source;
}

=head2 master_request_files

A list of request files for the source

=cut

has master_request_files => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy_build => 1,
);

sub _build_master_request_files {
    my $self = shift;

    my @master_files;
    push @master_files, @{$self->_vol_request_files};
    push @master_files, $self->_rates_request_file;
    push @master_files, $self->_forward_rates_request_file;
    push @master_files, @{$self->_ohlc_request_files};
    push @master_files, $self->_corporate_actions_request_files;

    return \@master_files;
}

has _corporate_actions_request_files => (
    is      => 'ro',
    isa     => 'Str',
    default => 'corporate_actions.req',
);

has _ohlc_request_files => (
    is         => 'ro',
    init_arg   => undef,
    isa        => 'ArrayRef',
    lazy_build => 1,
);

sub _build__ohlc_request_files {
    my $self = shift;

    my @list = ('ohlc_europe_i.req', 'ohlc_us_i.req', 'ohlc_OBX_i.req', 'ohlc_IBOV_i.req', 'ohlc_ISEQ_i.req', 'ohlc_TOP40_i.req');
    my @asia_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => 'indices',
        submarket         => 'asia_oceania',
        contract_category => 'ANY'
    );

    foreach my $symbol (@asia_symbols) {
        if ($symbol eq 'BSESENSEX30') {
            $symbol = 'SENSEX';
        }
        push @list, 'ohlc_' . $symbol . '_i.req';
    }

    return \@list;

}

has _rates_request_file => (
    is      => 'ro',
    isa     => 'Str',
    default => 'interest_rate.req',
);

has _forward_rates_request_file => (
    is      => 'ro',
    isa     => 'Str',
    default => 'forward_rates.req',
);

has _vol_request_files => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy_build => 1,
);

sub _build__vol_request_files {
    my $self = shift;

    my @list;
    if ($self->volatility_source eq 'OVDV') {
        @list = map { 'fxvol' . sprintf('%02d', $_) . '45_OVDV.req' } (0 .. 23);
    } else {    # it is 'vol_points'
        @list = map { 'fxvol' . sprintf('%02d', $_) . '45_points.req' } (0 .. 23);
        push @list, 'quantovol.req';
    }

    return \@list;
}

=head2 generate_request_fileq

Generates and writes all request files relevant to the source

    $rq = BOM::MarketData::Parser::Bloomberg::RequestFiles->new;
    $rq->generate_request_files('daily');
    $rq->generate_request_files('oneshot');

=cut

sub generate_request_files {
    my ($self, $flag) = @_;

    get_logger('QUANT')->logcroak('Undefined flag passed during request file generation') unless $flag;

    my $dir = $self->request_files_dir;
    my $file_identifier = ($flag eq 'daily') ? 'd' : 'os';

    # generates vol request files
    foreach my $volfile (@{$self->_vol_request_files}) {
        my $template;
        if ($volfile =~ /quantovol/) {
            $template = $self->_get_quanto_template($volfile, $flag);
        } else {
            $template = $self->_get_vols_template($volfile, $flag);
        }
        write_file($dir . '/' . $file_identifier . '_' . $volfile, $template);
    }

    # generates ohlc request files
    foreach my $ohlc (@{$self->_ohlc_request_files}) {
        my $template = $self->_get_ohlc_template($ohlc, $flag);
        write_file($dir . '/' . $file_identifier . '_' . $ohlc, $template);
    }

    my $rates_template = $self->_get_rates_template($flag);
    write_file($dir . '/' . $file_identifier . '_' . $self->_rates_request_file, $rates_template);

    my $forward_rates_template = $self->_get_forward_rates_template($flag);
    write_file($dir . '/' . $file_identifier . '_' . $self->_forward_rates_request_file, $forward_rates_template);

    write_file($dir . '/' . $file_identifier . '_' . $self->_corporate_actions_request_files, $self->_get_corporate_actions_template($flag));

    return 1;
}

=head2 generate_cancel_files

Generates and writes all cancel files relevant to the source

    $rq = BOM::MarketData::Parser::Bloomberg::RequestFiles->new;
    $rq->generate_cancel_files('daily');

=cut

sub generate_cancel_files {
    my ($self, $flag) = @_;
    my $source = $self->volatility_source;
    get_logger('QUANT')->logcroak('Undefined flag passed during request file generation') unless $flag;

    my $dir = $self->request_files_dir;
    foreach my $file (@{$self->master_request_files}) {

        if ($file =~ /^fxvol(\d\d45)_(OVDV|points)\.req$/) {
            $flag = ($source eq 'OVDV') ? 'daily' : 'weekday';
        }

        my $output_file = $file;
        $output_file =~ s/\.req$/.csv.enc/;
        my $template = $self->_process(
            'cancel',
            {
                outputfile => $output_file,
                flag       => $flag,
            });
        write_file($dir . '/c_' . $file, $template);
    }

    return 1;
}

sub _get_currency_list {
    my ($self, $what_list) = @_;

    my @quanto_fx = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market      => ['forex'],
        submarket   => ['major_pairs', 'minor_pairs'],
        quanto_only => 1,
    );
    my @quanto_commodity = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market      => ['commodities'],
        quanto_only => 1,
    );
    my @quanto_currencies = (@quanto_fx, @quanto_commodity);

    my @offered_fx = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => ['forex'],
        submarket         => ['major_pairs', 'minor_pairs'],
        contract_category => 'ANY',
        broker            => 'VRT',
    );
    my @offered_commodity = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => ['commodities',],
        contract_category => 'ANY',
        broker            => 'VRT',
    );
    my @offered_currencies = (@offered_fx, @offered_commodity);

    my @currencies =
        ($what_list eq 'all') ? (@offered_currencies, @quanto_currencies) : ($what_list eq 'offered_only') ? @offered_currencies : @quanto_currencies;

    return @currencies;
}

sub _tickerlist_vols {
    my ($self,    $args)         = @_;
    my ($include, $request_time) = @{$args}{qw(include request_time)};

    my @currencies = $self->_get_currency_list($include);

    my @list;
    my $source = $self->volatility_source;

    foreach my $symbol (@currencies) {
        # BROUSD is the generic oil future which does not have vol
        next
            if ($symbol eq 'frxBROUSD'
            or $symbol eq 'frxBROGBP'
            or $symbol eq 'frxBROEUR'
            or $symbol eq 'frxBROAUD'
            or $symbol eq 'frxXPDAUD'
            or $symbol eq 'frxXPTAUD');
        my $bbdl_info = BOM::Market::UnderlyingDB->instance->bbdl_parameters({symbol => $symbol});
        my $vol_source = $bbdl_info->{$symbol}{vol_source};

        $symbol =~ s/frx//;

        if ($source eq 'OVDV') {
            push @list, $symbol . ' Curncy';

        } else {    # it is 'vol_points'
            if ($request_time and not grep { $request_time eq $_ } ('0045', '0445', '0845', '1245', '1645', '2045')) {
                foreach my $term ('ON', '1W') {
                    push @list, $symbol . 'V' . $term . ' ' . $vol_source . ' Curncy';
                    push @list, $symbol . '25R' . $term . ' ' . $vol_source . ' Curncy';
                    push @list, $symbol . '25B' . $term . ' ' . $vol_source . ' Curncy';

                }
            } else {
                foreach my $term ('ON', '1W', '2W', '3W', '1M', '2M', '3M', '6M', '9M', '1Y') {
                    push @list, $symbol . 'V' . $term . ' ' . $vol_source . ' Curncy';
                    push @list, $symbol . '25R' . $term . ' ' . $vol_source . ' Curncy';
                    push @list, $symbol . '25B' . $term . ' ' . $vol_source . ' Curncy';

                }
            }
        }
    }

    return @list;
}

sub _get_corporate_actions_template {
    my ($self, $flag) = @_;

    my $now        = Date::Utility->new;
    my $start_date = $now->date_yyyymmdd;
    $start_date =~ s/\D//g;
    my $end_date = $now->plus_time_interval('180d')->date_yyyymmdd;
    $end_date =~ s/\D//g;
    my $date_range = $start_date . '|' . $end_date;
    my $list = join "\n", ($self->_tickerlist_stocks());

    return $self->_process(
        'corporate_actions',
        {
            date_range => $date_range,
            flag       => $flag,
            list       => $list,
        });
}

sub _get_quanto_template {
    my ($self, $volfile, $flag) = @_;
    $flag = 'weekday';
    $volfile =~ s/\.req$/.csv.enc/;
    my $output_file = $volfile;
    my @currencies  = $self->_get_currency_list('quanto_only');
    my @list;
    foreach my $symbol (@currencies) {
        # BROUSD is the generic oil future which does not have vol
        next
            if ($symbol eq 'frxBROUSD'
            or $symbol eq 'frxBROGBP'
            or $symbol eq 'frxBROEUR'
            or $symbol eq 'frxBROAUD'
            or $symbol eq 'frxXPDAUD'
            or $symbol eq 'frxXPTAUD');
        my $bbdl_info = BOM::Market::UnderlyingDB->instance->bbdl_parameters({symbol => $symbol});
        my $vol_source = $bbdl_info->{$symbol}{vol_source};
        $symbol =~ s/frx//;
        foreach my $term ('ON', '1W', '1M', '2M', '3M', '6M', '9M', '1Y') {
            push @list, $symbol . 'V' . $term . ' ' . $vol_source . ' Curncy';
        }
    }

    my $list_string = join "\n", @list;
    my $fields = "PX_LAST \nPX_ASK \nPX_BID";

    return $self->_process(
        'vols',
        {
            outputfile => $output_file,
            flag       => $flag,
            time       => undef,
            list       => $list_string,
            fields     => $fields,
        });
}

sub _get_vols_template {
    my ($self, $volfile, $flag) = @_;

    my $source = $self->volatility_source;

    $flag = ($source eq 'OVDV') ? 'daily' : 'weekday';
    my $include = ($source eq 'OVDV') ? 'all' : 'offered_only';
    my ($request_time) = $volfile =~ /^fxvol(\d\d45)_(OVDV|points)\.req$/;

    $volfile =~ s/\.req$/.csv.enc/;
    my $output_file = $volfile;

    my $list = join "\n",
        (
        $self->_tickerlist_vols({
                include      => $include,
                request_time => $request_time,
            }));

    my $fields = ($source eq 'OVDV') ? "DFLT_VOL_SURF_MID \nDFLT_VOL_SURF_SPRD" : "PX_LAST \nPX_ASK \nPX_BID";

    return $self->_process(
        'vols',
        {
            outputfile => $output_file,
            flag       => $flag,
            time       => $request_time,
            list       => $list,
            fields     => $fields,
        });
}

sub _get_forward_rates_template {
    my ($self, $flag) = @_;

    my $list         = _tickerlist_forward_rates();
    my $request_time = 2000;

    return $self->_process(
        'forward_rates',
        {
            flag => $flag,
            time => $request_time,
            list => $list,
        });
}

sub _get_rates_template {
    my ($self, $flag) = @_;

    my $interest_rates = tickerlist_interest_rates();
    my $request_time   = 2000;

    my @list;
    foreach my $currency (keys %{$interest_rates}) {
        foreach my $term (keys %{$interest_rates->{$currency}}) {
            push @list, $interest_rates->{$currency}->{$term};
        }
    }

    my $list = join "\n", @list;

    return $self->_process(
        'interest_rates',
        {
            flag => $flag,
            time => $request_time,
            list => $list,
        });
}

sub _get_ohlc_template {
    my ($self, $volfile, $flag) = @_;

    my ($which) = $volfile =~ /_(\w)\.req$/;
    my $request_time;
    my @symbols;
    my $fields = "PX_OPEN\nPX_HIGH\nPX_LOW\nPX_LAST_EOD\nLAST_UPDATE_DATE_EOD";

    if ($which eq 'i') {
        my ($region) = $volfile =~ /^ohlc_(\w+)_i\.req$/;
        my $index;
        if    ($region eq 'us')     { $index = 'DJI'; }
        elsif ($region eq 'europe') { $index = 'GDAXI'; }
        elsif ($region eq 'SENSEX') { $index = 'BSESENSEX30'; }
        else                        { $index = $region; }
        my $u     = BOM::Market::Underlying->new($index);
        my $today = Date::Utility->today;
        my $close = $u->exchange->closing_on($today);
        if (not $close) {
            my $previous_trading_day = $u->exchange->trade_date_before($today, {lookback => 1});
            $close = $u->exchange->closing_on($previous_trading_day);
        }
        my $r_time;
        # For this ISEQ, close price only update at 4 hours after market close,
        # hence request at 4h30m after market close
        if ($region eq 'ISEQ') {
            $r_time = Date::Utility->new($close->epoch + 16200);
        } else {
            $r_time = Date::Utility->new($close->epoch + 5400);
        }
        my $request_date = DateTime->new(
            year      => $r_time->year,
            month     => $r_time->month,
            day       => $r_time->day_of_month,
            hour      => $r_time->hour,
            minute    => $r_time->minute,
            second    => $r_time->second,
            time_zone => 'UTC',
        );
        $request_date->set_time_zone('Asia/Tokyo');
        my $hour = $request_date->hour;
        my $min  = $request_date->minute;
        if ($hour =~ /(^\d$)/) { $hour = '0' . $hour; }
        if ($min =~ /(^\d$)/)  { $min  = '0' . $min; }
        $request_time = $hour . $min;

        if ($region eq 'us' or $region eq 'europe') {
            foreach my $symbol (@{$self->get_all_indices_by_region->{$region}}) {
                next if ($symbol eq 'RTSI' or $symbol eq 'OBX' or $symbol eq 'IBOV' or $symbol eq 'ISEQ' or $symbol eq 'TOP40');
                if ($self->get_all_stocks_by_index($symbol)) {
                    push @symbols, $self->get_all_stocks_by_index($symbol);
                }
                push @symbols, $self->_rmg_to_bloomberg($symbol);
            }
        } else {
            if ($self->get_all_stocks_by_index($index)) {
                push @symbols, $self->get_all_stocks_by_index($index);
            }
            push @symbols, $self->_rmg_to_bloomberg($index);
        }
    } else {
        get_logger('QUANT')->logcroak("Invalid request file[$volfile]  for index/stock");
    }

    $volfile =~ s/\.req$/.csv.enc/;
    my $output_file = $volfile;

    my $list = join "\n", @symbols;

    return $self->_process(
        'ohlc',
        {
            outputfile => $output_file,
            flag       => $flag,
            time       => $request_time,
            fields     => $fields,
            list       => $list,
        });
}

sub tickerlist_interest_rates {

    my %interest_rates_tickerlist;

    my @currencies = @{BOM::MarketData::CurrencyConfig->new->{currency_list}};
    foreach my $currency (@currencies) {

        $interest_rates_tickerlist{$currency} = BOM::MarketData::CurrencyConfig->new(symbol => $currency)->bloomberg_interest_rates_tickerlist;
    }

    return \%interest_rates_tickerlist;
}

sub _tickerlist_forward_rates {

    my @quanto_currencies = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market      => 'forex',
        quanto_only => 1,
    );
    my @offered_currencies = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market => 'forex',
        broker => 'VRT',
    );

    my @currencies = (@quanto_currencies, @offered_currencies);

    my @list;
    my $list;
    foreach my $symbol (@currencies) {

        my $underlying = BOM::Market::Underlying->new($symbol);
        my $ticker     = $underlying->forward_tickers;
        foreach my $forward_ticker (keys %{$ticker}) {
            push @list, $ticker->{$forward_ticker};
        }

        $list = join "\n", @list;

    }
    return $list;

}

# Purpose: returns a list of stocks tickers for BBDL request file and office feed file
# Examples: AAL LN Equity ....
sub _tickerlist_stocks {
    my $self             = shift;
    my %bloomberg_to_rmg = $self->bloomberg_to_rmg('equities');
    my @list;

    foreach my $bb_code (keys %bloomberg_to_rmg) {
        next if (grep { $bloomberg_to_rmg{$bb_code} eq $_ } qw( USSEBL USVRTS USJDSU USPSFT UKOOM ));
        push @list, $bb_code;
    }

    return @list;
}

=head1 get_all_indices_by_region

=cut

sub get_all_indices_by_region {
    my $indices = BOM::Market::UnderlyingDB->instance->bbdl_parameters({market => 'indices'});
    my $regional_indices = {};
    foreach my $index (keys %{$indices}) {
        my $region = $indices->{$index}->{region};
        if ($region) {
            $regional_indices->{$region} = [] unless ($regional_indices->{$region});
            push @{$regional_indices->{$region}}, $index;
        }
    }

    return $regional_indices;
}

=head1 get_all_stocks_by_index

=cut

sub get_all_stocks_by_index {
    my ($self, $index) = @_;
    my @list;
# to match the stock's submarket with relevant index
    my %indices_stock_market = (
        FTSE  => 'uk',
        GDAXI => 'germany',
        FCHI  => 'france',
        AEX   => 'amsterdam',
        BFX   => 'belgium',
    );

    if ($indices_stock_market{$index}) {
        my @stocks = BOM::Market::UnderlyingDB->instance->get_symbols_for(
            market    => 'stocks',
            submarket => $indices_stock_market{$index},
        );
        foreach my $stock (@stocks) {
            push @list, $self->_rmg_to_bloomberg($stock);
        }
        return @list;
    }
}

sub _rmg_to_bloomberg {
    my ($self, $our_code) = @_;
    my %bloomberg_codes = $self->bloomberg_to_rmg;

    my %our_codes = reverse %bloomberg_codes;

    get_logger('QUANT')->logcroak("Cannot parse [$our_code]") unless $our_codes{$our_code};

    return $our_codes{$our_code};
}

has bloomberg_symbol_mapping => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_bloomberg_symbol_mapping {
    my $self = shift;

    my $udb = BOM::Market::UnderlyingDB->instance;

    my %bloomberg_codes;
    foreach my $market (qw(forex commodities indices sectors)) {
        my $list = $udb->bbdl_bom_mapping_for({market => $market});
        %{$bloomberg_codes{$market}} = map { $_ => $list->{$_} } keys %{$list};
    }

    my $stocks = $udb->bbdl_bom_mapping_for({market => 'stocks'});
    %{$bloomberg_codes{equities}} = map { $_ => $stocks->{$_} } keys %{$stocks};

    #This stuff still remains here has I do not see a natural file to push it into.
    my %currency_equivalents = (
        US   => 'USD',
        EU   => 'EUR',
        CK   => 'CZK',
        DK   => 'DKK',
        HF   => 'HUF',
        JY   => 'JPY',
        SF   => 'CHF',
        BP   => 'GBP',
        CD   => 'CAD',
        NK   => 'NOK',
        PZ   => 'PLN',
        SK   => 'SEK',
        XU   => 'XAD',    #won't work
        NZ   => 'NZD',
        AU   => 'AUD',
        KRBO => 'KRW',
        HIHD => 'HKD',
        SIBC => 'SGD',
        JIIN => 'IDR',
        SHIF => 'CNY',
    );

    %{$bloomberg_codes{currencies}} = map { $_ => $currency_equivalents{$_} } keys %currency_equivalents;

    return \%bloomberg_codes;
}

=head2 bloomberg_to_rmg

Returns a hash mapping Bloomberg symbol codes to RMG equivalents.

=cut

sub bloomberg_to_rmg {
    my ($self, $type) = @_;
    $type ||= '';

    my %codes;
    if ($type) {
        %codes = %{$self->bloomberg_symbol_mapping->{$type}};
    } else {
        foreach my $market (values %{$self->bloomberg_symbol_mapping}) {
            %codes = (%codes, %$market);
        }
    }

    return %codes;
}

sub _get_historical_data_template {
    my ($self, $start_time, $underlying) = @_;
    my $end_time   = Date::Utility->new($start_time)->plus_time_interval('2d');
    my $start_date = Date::Utility->new($start_time)->date_yyyymmdd;
    my $end_date   = Date::Utility->new($end_time)->date_yyyymmdd;
    $start_date =~ s/-//g;
    $end_date =~ s/-//g;

    my $underlying_file_name = $underlying;
    $underlying_file_name =~ s/\s//g;
    $underlying_file_name =~ s/Index//g;
    my $reply_file_name = "$underlying_file_name" . '_' . "$start_date";

    return $self->_process(
        'historical_data',
        {
            reply_file_name => $reply_file_name,
            start_date      => $start_date,
            end_date        => $end_date,
            list            => $underlying,
        });
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
