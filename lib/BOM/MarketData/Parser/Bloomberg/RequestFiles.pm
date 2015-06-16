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
use warnings;
use Carp;
use Date::Utility;
use Bloomberg::UnderlyingConfig;
use Bloomberg::CurrencyConfig;
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
    default => sub { '/home/tmpramdrive'},
);

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
    my $ohlc_request_file = Bloomberg::UnderlyingConfig->get_underlyings_with_ohlc_request();
    my %list = map{ $_, 0} map { $ohlc_request_file->{$_}->{file_name}} keys %{$ohlc_request_file};

    return keys %list;

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

    my @list = map { 'fxvol' . sprintf('%02d', $_) . '45_points.req' } (0 .. 23);
    push @list, 'quantovol.req';

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

    croak 'Undefined flag passed during request file generation' unless $flag;

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
    croak 'Undefined flag passed during request file generation' unless $flag;

    my $dir = $self->request_files_dir;
    foreach my $file (@{$self->master_request_files}) {

        if ($file =~ /^fxvol(\d\d45)_points\.req$/) {
            $flag = 'weekday';
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


sub _tickerlist_vols {
    my ($self,    $args)         = @_;
    my ($include, $request_time) = @{$args}{qw(include request_time)};

    my @currencies = Bloomberg::UnderlyingConfig->get_currencies_list($include);

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
        my $vol_source = Bloomberg::UnderlyingConfig->get_underlying_parameters_for($symbol)->{vol_source};

        $symbol =~ s/frx//;

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
    my @stocks_list = Bloomberg:UnderlyingConfig->get_stocks_list();
    my $list = join "\n", (@stocks_list);

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
    my @currencies  = Bloomberg::UnderlyingConfig->get_currencies_list('quanto_only');
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
        my $vol_source = Bloomberg::UnderlyingConfig->get_underlying_parameters_for($symbol)->{vol_source};
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


    $flag =  'weekday';
    my $include =  'offered_only';
    my ($request_time) = $volfile =~ /^fxvol(\d\d45)_points\.req$/;

    $volfile =~ s/\.req$/.csv.enc/;
    my $output_file = $volfile;

    my $list = join "\n",
        (
        $self->_tickerlist_vols({
                include      => $include,
                request_time => $request_time,
            }));

    my $fields = "PX_LAST \nPX_ASK \nPX_BID";

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

     my @list = Bloomberg::UnderlyingConfig->get_forward_tickers_list();

    my $list         = join "\n", @list;
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

    my %interest_rates = Bloomberg::CurrencyConfig->get_interest_rate_list();
    my $request_time   = 2000;

    my @list;
    foreach my $currency (keys %interest_rates) {
        foreach my $term (keys %{$interest_rates{$currency}}) {
            push @list, $interest_rates{$currency}{$term};
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
    my ($self, $file, $flag) = @_;

    my $all = Bloomberg::UnderlyingConfig->get_underlyings_with_ohlc_request();
    my @symbols = grep { $all->{$_}->{file_name} eq $file} keys %{$all};
    my $fields = "PX_OPEN\nPX_HIGH\nPX_LOW\nPX_LAST_EOD\nLAST_UPDATE_DATE_EOD";
    $file =~ s/\.req$/.csv.enc/;
    my $output_file = $file;
    my $request_time ;
    my $date = Date::Utility->new;
    if (scalar(keys %{$all->{$symbol[0]}->{request_time}}) > 1){
       if ($date->is_dst_in_zone($all->{$symbol[0]}->{region}){
          $request_time = $all->{$symbols[0]}->{request_time}->{dst};
        }else{
          $request_time = $all->{$symbols[0]}->{request_time}->{standard};
        }
    }else {
      $request_time = $all->{$symbols[0]}->{request_time};
    }
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
