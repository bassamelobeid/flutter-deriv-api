#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use Date::Utility;
use JSON::MaybeXS;
use LandingCompany::Registry;
use f_brokerincludeall;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::QuantsConfigHelper;
use BOM::Platform::Email qw(send_email);
use BOM::Config::Runtime;
use Brands;

BOM::Backoffice::Sysinit::init();
my $json  = JSON::MaybeXS->new;
my $staff = BOM::Backoffice::Auth0::get_staffname();

if (request()->param('save_limit')) {
    my %args = map { $_ => request()->param($_) }
        qw(market new_market expiry_type contract_group underlying_symbol landing_company barrier_type limit_type limit_amount comment start_time end_time);

    my %email_args = (%args, action => 'New');
    my $output = BOM::Backoffice::QuantsConfigHelper::save_limit(\%args, $staff);
    print $json->encode($output);

    if (!$output->{error}) {
        my %email = _format_email_for_limit(%email_args);
        _send_compliance_email(%email);
    }
}

if (request()->param('delete_market_group')) {
    my %args = map { $_ => request()->param($_) } qw(market landing_company start_time end_time symbol);
    print $json->encode(BOM::Backoffice::QuantsConfigHelper::delete_market_group(\%args));
}

if (request()->param('delete_limit')) {
    my %args =
        map { $_ => request()->param($_) }
        qw(market expiry_type contract_group underlying_symbol landing_company barrier_type type limit_type start_time end_time);

    my %email_args = (%args, action => 'Deleted');
    my $output = BOM::Backoffice::QuantsConfigHelper::delete_limit(\%args, $staff);
    print $json->encode($output);

    if (!$output->{error} && $output->{deleted}) {
        my %email = _format_email_for_limit(%email_args);
        _send_compliance_email(%email);
    }
}

if (request()->param('update_contract_group')) {
    my %args = map { $_ => request()->param($_) } qw(contract_group contract_type);
    print $json->encode(BOM::Backoffice::QuantsConfigHelper::update_contract_group(\%args));
}

if (request()->param('update_market_group')) {
    my %args = map { $_ => request()->param($_) } qw(underlying_symbol market_group submarket_group market_type);
    print $json->encode(BOM::Backoffice::QuantsConfigHelper::update_market_group(\%args));
}

if (request()->param('save_threshold')) {
    my %args = map { $_ => request()->param($_) } qw(limit_type threshold_amount);

    my $app_config     = BOM::Config::Runtime->instance->app_config;
    my $threshold_name = $args{limit_type} . '_alert_threshold';
    my $prev_value     = $app_config->quants->$threshold_name;

    my $output = BOM::Backoffice::QuantsConfigHelper::save_threshold(\%args, $staff);
    print $json->encode($output);

    if (!$output->{error}) {
        my %email = _format_email_for_user_limit_threshold(
            prev_value => $prev_value,
            cur_value  => $args{threshold_amount},
            limit_type => $args{limit_type},
        );
        _send_compliance_email(%email);
    }
}

if (request()->param('update_config_switch')) {
    my %args = map { $_ => request()->param($_) } qw(limit_type limit_status);

    my $output = BOM::Backoffice::QuantsConfigHelper::update_config_switch(\%args, $staff);
    print $json->encode($output);

    if (!$output->{error}) {
        my %email = _format_email_for_config_switch(%args);
        _send_compliance_email(%email);
    }
}

sub _format_email_for_user_limit_threshold {
    my %args       = @_;
    my $limit_type = $args{limit_type} =~ s/_/ /gr =~ s/\b(\w)/\U$1/gr;

    my $staff    = BOM::Backoffice::Auth0::get_staffname();
    my $datetime = Date::Utility->new->datetime;

    my $message = "\
    $limit_type is updated from $args{prev_value} to $args{cur_value}

    by $staff on $datetime\n";

    return (
        message => [$message],
        subject => "$limit_type set to $args{cur_value}"
    );
}

sub _format_email_for_config_switch {
    my %args = @_;

    my $staff    = BOM::Backoffice::Auth0::get_staffname();
    my $datetime = Date::Utility->new->datetime;
    my $status   = $args{limit_status} ? "On" : "Off";
    my $limit    = $args{limit_type} =~ s/\_/ /gr =~ s/\b(\w)/\U$1/gr;

    my $message = "\
    Quants Config Switch:

    $limit Turned $status by $staff on $datetime

    ";

    return (
        message => [$message],
        subject => "$limit Turned $status",
    );
}

sub _format_email_for_limit {
    my %args = @_;

    if (defined $args{start_time}) {
        for my $time (qw/ start_time end_time /) {
            $args{$time} =~ s/[^\d\-\:\w]+/ /g;
            $args{$time} =~ s/^\s*(.+?)\s*$/$1/;
            if ($args{$time} =~ /^\d\d\d\d\-\d\d?\-\d\d?$/) {
                $args{$time} .= $time eq 'start_time' ? ' 00:00:00' : ' 24:00:00';
            } else {
                $args{$time} =~ s/^(\d\d)(\d\d)$/$1:$2:00/;
                $args{$time} =~ s/^(\d\d)(\d\d)(\d\d)$/$1:$2:$3/;
                $args{$time} =~ s/^(\d\d?)$/$1:00:00/;
                $args{$time} =~ s/^(\d\d\d\d\-\d\d?\-\d\d? \d\d?)$/$1:00:00/;
                if ($args{$time} =~ /^\s*\d[\d:]{0,7}\s*$/) {
                    $args{$time} = Date::Utility->new->date . " $args{$time}";
                }
            }
        }
    }

    my $staff = BOM::Backoffice::Auth0::get_staffname();
    # cleanup args
    for my $key (keys %args) {
        $args{$key} = !$args{$key} || $args{$key} eq 'default' ? '-' : $args{$key};
        if ($key =~ /market|expiry_type|barrier_type|contract_group|landing_company/) {
            $args{$key} =~ s/&/, /g;
            $args{$key} =~ s/(\w+)=(\w+)/$2/g;
            $args{$key} =~ s/\b(\w)/\U$1/g;
        }
        if ($key =~ /limit_type/) {
            $args{$key} =~ s/\_/ /g;
            $args{$key} =~ s/\b(\w)/\U$1/g;
        }
    }

    my $datetime = Date::Utility->new->datetime;
    my $market = $args{market} eq '-' ? $args{new_market} : $args{market};
    $market = '-' if !defined($market);
    my $between = ($args{start_time} ne '-') || ($args{end_time} ne '-') ? "between $args{start_time} to $args{end_time}" : '';

    # format email body
    my $message = "\
    $args{action} $args{limit_type} for $market $args{expiry_type} $between

    Market:          $market
    Underlying:      $args{underlying_symbol}
    Expiry Type:     $args{expiry_type}
    Barrier Type:    $args{barrier_type}
    Contract Group:  $args{contract_group}
    Landing Company: $args{landing_company}
    Limit Type:      $args{limit_type}"
        . (
        $args{limit_amount} ? "\n    Limit Amount:    $args{limit_amount}"
        : ''
        )
        . (
        $args{comment} ? "\n    Comment:         $args{comment}"
        : ''
        )
        . (
        $args{start_time} ? "\n    Start Time:      $args{start_time}"
        : ''
        )
        . (
        $args{end_time} ? "\n    End Time:        $args{end_time}"
        : ''
        ) . "\n\n    By $staff on $datetime\n";
    return (
        message => [$message],
        subject => "$args{action} $args{limit_type} for $market $args{expiry_type} $between",
    );
}

# Why does compliance need this email?
#
# > Just to give you the full picture, the MFSA request was that the head of risk for BIEL would need to approve any changes before these are done.
# > As a compromise, as this is not feasible, we will inform them that the head of risk will be notified when the risk profile and global limits are changed.
sub _send_compliance_email {
    my %args = @_;

    my $brand = Brands->new(name => request()->brand);
    # send an email to compliance
    my $recipients = join(',', $brand->emails('compliance'), $brand->emails('alert_quants'));
    send_email({
        from    => $brand->emails('system'),
        to      => $recipients,
        subject => $args{subject},
        message => $args{message},
    });
    return;
}
