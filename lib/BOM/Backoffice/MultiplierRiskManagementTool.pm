package BOM::Backoffice::MultiplierRiskManagementTool;

use strict;
use warnings;
use Date::Utility;
use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;
use Text::Trim qw(trim);
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use Syntax::Keyword::Try;

=head2 validate_deal_cancellation_args

validate_deal_cancellation_args is for deal cancellation args validation.

=cut

sub validate_deal_cancellation_args {
    my $args = shift;

    my $underlying_symbol    = $args->{underlying_symbol};
    my $landing_companies    = $args->{landing_companies};
    my $dc_types             = $args->{dc_types};
    my $start_datetime_limit = $args->{start_datetime_limit};
    my $end_datetime_limit   = $args->{end_datetime_limit};
    my $dc_comment           = $args->{dc_comment};

    return {error => "Underlying Symbol is required"} if !$underlying_symbol;
    return {error => "Landing Company is required"}   if !$landing_companies;
    return {error => "Start time is required"}        if !$start_datetime_limit;
    return {error => "End time is required"}          if !$end_datetime_limit;
    return {error => "Comment is required"}           if !$dc_comment;

    my $start_dt = Date::Utility->new($start_datetime_limit . ":00");
    my $end_dt   = Date::Utility->new($end_datetime_limit . ":00");
    return {error => "Start time must be before end time"} if $start_dt->epoch >= $end_dt->epoch;

    my @dc_types = split(',', $dc_types);
    @dc_types = trim(@dc_types);

    my $multiplier_default_config = BOM::Config::QuantsConfig->get_multiplier_config_default();
    my @default_dc_configs        = @{$multiplier_default_config->{"common"}{$underlying_symbol}{cancellation_duration_range}};
    if ($dc_types) {
        foreach my $dc_type (@dc_types) {
            if (!grep { m/^$dc_type$/ } @default_dc_configs) {
                return {error => "Deal Cancellation duration: Please input existing duration"};
            }
        }

        $args->{dc_types} = join(',', @dc_types);
    } else {
        $args->{dc_types} = "";
    }

    # Prepare data to be saved
    $args->{start_datetime_limit} = $start_datetime_limit . ":00";
    $args->{end_datetime_limit}   = $end_datetime_limit . ":00";

    return $args;
}

=head2 save_deal_cancellation

"save" method for deal cancellation.

How to use: BOM::Backoffice::MultiplierRiskManagementTool::save_deal_cancellation($key, $name, $validated_dc_arg)
where, $key = "deal_cancellation", $name = unique name, $validated_dc_arg = data that need to be saved.

=cut

sub save_deal_cancellation {
    my ($key, $name, $args) = @_;
    my $now = Date::Utility->new();
    my $qc  = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        recorded_date    => $now,
    );
    my $dc_config = $qc->get_config($key) // {};

    try {
        if (exists $dc_config->{"$name"}) {
            $qc->delete_config($key, $name);
        }

        $dc_config->{"$name"} = $args;
        $qc->save_config($key, $dc_config);
        send_trading_ops_email("Deal Cancellation Quant's tool: add new config", $args);

        return {success => 1};
    } catch ($e) {
        return {error => 'ERR: ' . $e};
    }
}

=head2 destroy_deal_cancellation

"delete" method for deal cancellation.

How to use: BOM::Backoffice::MultiplierRiskManagementTool::destroy_deal_cancellation($key, $dc_id)
where, $key = "deal_cancellation", $dc_id = unique name.

=cut

sub destroy_deal_cancellation {
    my ($key, $dc_id) = @_;
    my $qc = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        recorded_date    => Date::Utility->new,
    );
    my $dc_config = $qc->get_config($key) // {};

    try {
        if (exists $dc_config->{"$dc_id"}) {
            $qc->delete_config($key, $dc_id);
            send_trading_ops_email("Deal Cancellation Quant's tool: deleted config", {delete_config => $dc_id});

            return {success => 1};
        } else {
            return {error => 'Error: Please contact Quants Dev!'};
        }
    } catch ($e) {
        return {error => 'ERR: ' . $e};
    }
}

1;
