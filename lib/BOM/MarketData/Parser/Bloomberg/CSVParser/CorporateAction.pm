package BOM::MarketData::Parser::Bloomberg::CSVParser::CorporateAction;

=head1 NAME

BOM::MarketData::Parser::Bloomberg::CSVParser::CorporateActions

=head1 DESCRIPTION

Responsible to process and updates corporate actions information from Bloomberg Data License

my $corp = BOM::MarketData::Parser::Bloomberg::CSVParser::CorporateActions->new;
$corp->update_corporate_actions($file);

=cut

use Moose;
use File::Slurp;

use Date::Utility;
use BOM::MarketData::CorporateAction;
use BOM::MarketData::Parser::Bloomberg::RequestFiles;
use BOM::Market::Underlying;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Context qw(localize);
use Format::Util::Numbers qw(roundnear);

has _logger => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__logger {
    return get_logger;
}

=head2 update_corporate_actions

process file to BOM usable format and saves the data in couch database

=cut

sub process_data {
    my ($self, $file) = @_;

    my @lines = read_file($file);
    my @valid_actions;

    foreach my $line (@lines) {
        next if $line =~ /^#/;    # skips commented lines returned by Bloomberg
        my @corp_info = split '\|', $line;
        # return code of 300 indicates that no action is returned.
        # we are skipping this
        next if $corp_info[3] == 300;
        chomp $line;
        my $data   = $self->_get_corp_actions_info($line);
        my $action = $self->_convert_data_to_actions($data);
        push @valid_actions, $action if $action;
    }

    my %grouped_actions;
    foreach my $action (@valid_actions) {
        my $symbol    = $action->{symbol};
        my $action_id = $action->{action_id};
        delete $action->{action_id};
        delete $action->{symbol};
        $grouped_actions{$symbol}->{$action_id} = $action;
    }

    return %grouped_actions;
}

sub _get_corp_actions_info {
    my ($self, $line) = @_;

    my $output;

    my @line = split /\|/, $line;

    my @fields_default = (
        'Identifier',          'BB_CO_ID',    'BB_SEC_ID',  'Rcode',    'Action_ID',    'Mnemonic',
        'Flag',                'CO_Name',     'SecID_Type', 'SecID',    'Currency',     'Market_Sector_Des',
        'Bloomberg Unique ID', 'Ann_date',    'Eff_date',   'Amd_date', 'BB_GLOBAL_ID', 'BB_GLOBAL_CO_ID',
        'BB_SEC_ID_NO',        'FEED_SOURCE', 'Nfields'
    );

    while (scalar(@line) > scalar(@fields_default)) {
        my $bbdl_value = pop @line;
        my $bbdl_key   = pop @line;
        #Fix the problem that bloomberg send us .06 instead of 0.06 sometime
        $bbdl_value =~ s/^(\.\d+)/0$1/;
        $output->{$bbdl_key} = $bbdl_value;
    }

    my $variable_data          = scalar(keys %{$output});
    my $variable_data_expected = $line[-1];

    if ($variable_data != $variable_data_expected) {
        $self->_logger->logwarn('Errorneous corporate actions data for ' . $line[0] . ' received from Bloomberg');
    }

    @{$output}{@fields_default} = @line;

    return $output;
}

has _accepted_actions => (
    is      => 'ro',
    default => sub { [qw(SPIN RIGHTS_OFFER BANCR STOCK_BUY EQY_OFFER ACQUIS DIVEST EXCH_OFFER DVD_STOCK DVD_CASH STOCK_SPLT)] },
);

has _ignore_list => (
    is      => 'ro',
    default => sub {
        {
            STOCK_SPLT => {ignore => [3002, 3004, 3006, 3009, 3010, 3011]},
            DVD_STOCK  => {
                ignore => [2010, 2012, 2015],
            },
        };
    },
);

###################### _convert_bbdl_action ####################################
# Purpose: convert raw to relevant data
# Input: raw corporate actions data from bbdl
# Output: a hash reference of relevant action's information.
################################################################################
sub _convert_data_to_actions {
    my ($self, $corp_info) = @_;

    my $action_code = $corp_info->{Mnemonic};
    my $now         = Date::Utility->new;

    # only parse actions that we are interested in
    return if !grep { $action_code eq $_ } @{$self->_accepted_actions};

    # Corporate action is considered invalid when 'Eff_date' = 'N.A.' or 'CP_INDICATOR' = 'T'
    return
           if not defined $corp_info->{Eff_date}
        or $corp_info->{'Eff_date'} eq 'N.A.'
        or Date::Utility->new($corp_info->{'Eff_date'})->epoch < $now->epoch;
    return if defined $corp_info->{CP_INDICATOR} and $corp_info->{'CP_INDICATOR'} eq 'T';

    # ignore if actions doesn't change price of stocks
    return if ($action_code eq 'DVD_STOCK'  and grep { $corp_info->{CP_DVD_STOCK_TYP} == $_ } @{$self->_ignore_list->{DVD_STOCK}->{ignore}});
    return if ($action_code eq 'STOCK_SPLT' and grep { $corp_info->{CP_STOCK_SPLT_TYP} == $_ } @{$self->_ignore_list->{STOCK_SPLT}->{ignore}});

    my $logger = $self->_logger;
    #CP_AMT: Percent of each share held to be given to shareholders.
    #CP_ADJ: Price adjustment factor. Used for adjusting historical values.
    if ($action_code eq 'DVD_STOCK' and (1 + roundnear(0.0001, $corp_info->{'CP_AMT'} / 100)) != roundnear(0.0001, $corp_info->{'CP_ADJ'})) {
        $logger->logwarn('Corporate action ignored[' . $corp_info->{Action_ID} . ']. CP_ADJ is != 1+(CP_AMT/100) in DVD stock');
    }

    # For stock split, CP_ADJ will always equal with CP_RATIO, except for CP_STOCK_SPLT_TYP 3006
    # which is split action with no adjustment, this might be needed for example for pending listed security with no available
    # prices yet. For more information see for example BBDL
    if (    $action_code eq 'STOCK_SPLT'
        and $corp_info->{'CP_STOCK_SPLT_TYP'}
        and $corp_info->{'CP_STOCK_SPLT_TYP'} != 3006
        and $corp_info->{'CP_RATIO'} != $corp_info->{'CP_ADJ'})
    {
        $logger->logwarn('Corporate action ignored['
                . $corp_info->{Action_ID}
                . ']. CP_RATIO['
                . $corp_info->{CP_RATIO}
                . '] != CP_ADJ['
                . $corp_info->{CP_ADJ}
                . ']');
        return;
    }
    if ($corp_info->{CP_ADJ_DT} and $corp_info->{Eff_date} and $corp_info->{'CP_ADJ_DT'} ne $corp_info->{'Eff_date'}) {
        $logger->logwarn('Corporate action ignore['
                . $corp_info->{Action_ID}
                . ']. Adjustment date['
                . $corp_info->{CP_ADJ_DT}
                . '] != Effective date['
                . $corp_info->{Eff_date}
                . ']');
        return;
    }

    my %bloomberg_to_rmg = BOM::MarketData::Parser::Bloomberg::RequestFiles->new->bloomberg_to_rmg;
    $corp_info->{Identifier} =~ s/\s+/ /g;    # remove double spaces
    my $underlying_symbol = $bloomberg_to_rmg{$corp_info->{Identifier}};

    if ($corp_info->{Flag} eq 'D' and $corp_info->{Action_ID}) {
        # no further information is required for a deleted
        # corporate actions.
        return {
            flag      => $corp_info->{Flag},
            action_id => $corp_info->{Action_ID},
            symbol    => $underlying_symbol,
        };
    }

    my $underlying = BOM::Market::Underlying->new($underlying_symbol);
    my %actions    = (
        symbol         => $underlying->symbol,
        flag           => $corp_info->{Flag},
        effective_date => $corp_info->{Eff_date},
        action_id      => $corp_info->{Action_ID},
        type           => $action_code,
    );

    my %name_mapper = (
        DVD_CASH     => localize('Cash Dividend'),
        DVD_STOCK    => localize('Stock Dividend'),
        STOCK_SPLT   => localize('Stock Split'),
        DIVEST       => localize('Divestiture'),
        ACQUIS       => localize('Acquisition'),
        RIGHTS_OFFER => localize('Rights Offering'),
        SPIN         => localize('Spin-Off'),
        BANCR        => localize('Bankruptcy Filing'),
        STOCK_BUY    => localize('Stock Buyback'),
        EQY_OFFER    => localize('Equity Offering'),
        EXCH_OFFER   => localize('Exchange Offering'),
    );
    my $cp_terms = $corp_info->{CP_TERMS} || 'N.A.';

    if ($action_code eq 'ACQUIS') {
        $actions{description} = $name_mapper{$action_code};
    } elsif ($action_code eq 'DIVEST') {
        $actions{description} = $name_mapper{$action_code} . ' (' . $corp_info->{CP_UNIT} . ')';
    } elsif (
        grep {
            $action_code eq $_
        } qw(STOCK_SPLT RIGHTS_OFFER SPIN BANCR)
        )
    {
        $actions{description} = $name_mapper{$action_code} . ' (' . $corp_info->{CP_TERMS} . ')';
    } else {
        $actions{description} = $name_mapper{$action_code} . ' (' . $corp_info->{CP_NOTES} . ')';
    }

    #For Dividend Stock, the CP_AMT is the % of each share held to be given to shareholders
    if ($action_code eq 'STOCK_SPLT') {
        $actions{modifier}    = 'divide';
        $actions{value}       = $corp_info->{CP_ADJ};
        $actions{action_code} = $corp_info->{CP_STOCK_SPLT_TYP};
    } elsif ($action_code eq 'DVD_CASH') {
        $actions{'value'} = $corp_info->{'CP_GROSS_AMT'};
    } elsif ($action_code eq 'DVD_STOCK') {
        $actions{'modifier'}  = 'divide';
        $actions{'value'}     = 1 + ($corp_info->{'CP_AMT'} / 100);
        $actions{action_code} = $corp_info->{CP_DVD_STOCK_TYP};
    } elsif ($action_code eq 'BANCR') {
        $actions{suspend_trading} = 1;
        $actions{disabled_date}   = Date::Utility->new->datetime_iso8601;
    } elsif (
        grep {
            $action_code eq $_
        } qw(SPIN RIGHTS_OFFER STOCK_BUY EQY_OFFER ACQUIS DIVEST EXCH_OFFER)
        )
    {
        $actions{monitor}      = 1;
        $actions{monitor_date} = Date::Utility->new->datetime_iso8601;
    }

    if ($corp_info->{'CP_ADJ_DT'} and $corp_info->{'CP_ADJ_DT'} =~ /(\d{1,2})\/(\d{1,2})\/(\d{4})/) {
        my $release_date = Date::Utility->new($3 . '-' . sprintf('%02d', $1) . '-' . sprintf('%02d', $2));
        return if $now->is_before($release_date);
        $actions{date} = $release_date->date_ddmmmyy;
    }

    return \%actions;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
