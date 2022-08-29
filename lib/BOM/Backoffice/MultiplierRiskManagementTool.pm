package BOM::Backoffice::MultiplierRiskManagementTool;

use strict;
use warnings;
use Date::Utility;
use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;
use Text::Trim                        qw(trim);
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use Syntax::Keyword::Try;

=head2 validate_deal_cancellation_args

validate_deal_cancellation_args is for deal cancellation args validation.

=cut

sub validate_deal_cancellation_args {
    my $args = shift;

    my $underlying_symbol = $args->{underlying_symbol};
    my $landing_companies = $args->{landing_companies};
    my $dc_types          = $args->{dc_types};
    my $start_date_limit  = $args->{start_date_limit};
    my $start_time_limit  = $args->{start_time_limit};
    my $end_date_limit    = $args->{end_date_limit};
    my $end_time_limit    = $args->{end_time_limit};
    my $dc_comment        = $args->{dc_comment};

    return {error => "Underlying Symbol is required"} if !$underlying_symbol;
    return {error => "Landing Company is required"}   if !$landing_companies;
    return {error => "End time is required when Start time is given and vice versa!"}
        if ($end_time_limit xor $start_time_limit);
    return {error => "End date is required when Start date is given and vice versa!"}
        if (!$end_date_limit && $start_date_limit) || ($end_date_limit && !$start_date_limit);
    return {error => "Comment is required"} if !$dc_comment;

    my $config_has_no_limits = !$start_date_limit && !$start_time_limit && !$end_date_limit && !$end_time_limit;

    unless ($config_has_no_limits) {
        return {error => "Start time value is not valid."} unless _time_input_is_valid($start_time_limit);
        return {error => "End time value is not valid."}   unless _time_input_is_valid($end_time_limit);

        my ($start_datetime_limit, $start_dt) = _get_datetime_value($start_date_limit, $start_time_limit);
        my ($end_datetime_limit,   $end_dt)   = _get_datetime_value($end_date_limit,   $end_time_limit);

        return {error => "Start time must be before end time"} if $start_dt->epoch >= $end_dt->epoch;

        $args->{start_datetime_limit} = $start_datetime_limit;
        $args->{end_datetime_limit}   = $end_datetime_limit;
    } else {
        $args->{start_datetime_limit} = '00:00:00';
        $args->{end_datetime_limit}   = '23:59:59';
    }

    # Removing all of the excess arguments.
    delete $args->{start_time_limit};
    delete $args->{end_time_limit};
    delete $args->{start_date_limit};
    delete $args->{end_date_limit};

    my @dc_types = split(',', $dc_types);
    @dc_types = trim(@dc_types);

    my $multiplier_default_config = BOM::Config::QuantsConfig->get_multiplier_config_default();
    my @default_dc_configs;

    my @underlying_symbol_array = split(',', $underlying_symbol);
    foreach my $u_s (@underlying_symbol_array) {
        @default_dc_configs = @{$multiplier_default_config->{"common"}{$u_s}{cancellation_duration_range}};
    }

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

    return $args;
}

=head2 prepare_dc_args_for_create

prepare_dc_args_for_create is pre-processing the new deal cancellation config arguments.

=cut

sub prepare_dc_args_for_create {
    my $args = validate_deal_cancellation_args(shift);

    return $args if $args->{error};

    my @underlying_symbol_array = split(',', $args->{underlying_symbol});
    my $len                     = scalar @underlying_symbol_array;
    my @args_array              = ();

    # Copying all of the arg data and push them to an array at the end.
    for (0 .. $len) {
        next if (!defined $underlying_symbol_array[$_]);
        my $arg_copy = {%$args};
        $arg_copy->{underlying_symbol} = $underlying_symbol_array[$_];
        push @args_array, $arg_copy;
    }

    return \@args_array;
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

=head2 update_deal_cancellation

"update" method for deal cancellation.

How to use: BOM::Backoffice::MultiplierRiskManagementTool::update_deal_cancellation($key, $dc_id, $new_config)
where, $key = "deal_cancellation", $dc_id = unique name and $new_config = "{start_date => '2022-06-15'}".

=cut

sub update_deal_cancellation {
    my ($key, $dc_id, $new_config) = @_;
    my $qc = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        recorded_date    => Date::Utility->new,
    );
    my $dc_config = $qc->get_config($key) // {};
    my $new_dc_id = $new_config->{underlying_symbol} . "_" . $new_config->{landing_companies};

    try {
        if (!exists $dc_config->{"$dc_id"}) {
            return {error => 'Error: Please contact Quants Dev!'};
        }

        # Remove the old key since changing landing company will change the config key as well.
        $qc->delete_config($key, $dc_id);
        delete $dc_config->{$dc_id};

        # Replacing new config with the new key.
        $new_config->{id}          = $new_dc_id;
        $dc_config->{"$new_dc_id"} = $new_config;

        $qc->save_config($key, $dc_config);
        send_trading_ops_email("Deal Cancellation Quant's tool: updated config", {update_config => $dc_id});

        return {success => 1};
    } catch ($e) {
        return {error => 'ERR: ' . $e};
    }
}

=head2 _time_input_is_valid

Validating time inputs in case anyone decided to set 32:79:80 as start time.

=cut

sub _time_input_is_valid {
    my $time = shift;

    return 1 unless $time;

    try {
        Date::Utility->new("2000-01-01 " . $time);
    } catch {
        return 0;
    }

    return 1;
}

=head2 _get_datetime_value

Returning the proper date_time value depending on the given format.

=cut

sub _get_datetime_value {
    my ($date, $time) = @_;

    if ($date && $time) {
        my $datetime_limit = $date . " " . $time;
        return $datetime_limit, Date::Utility->new($datetime_limit);
    }

    if ($date) {
        return $date, Date::Utility->new($date);
    }

    # The 2000-01-01 date is just given to suppress errors of Date::Utility, since we only want to compare time this time.
    return $time, Date::Utility->new("2000-01-01 " . $time);
}

1;
