#!/usr/bin/perl

package BOM::System::Script::MyaffiliateCommission;

=head1 NAME

BOM::System::Script::MyaffiliateCommission

=head1 DESCRIPTION

Calculate monthly affiliate's commission, insert into db for data_collection.myaffiliates_commission table

=cut

use Moose;
use BOM::Database::ClientDB;
use DateTime;
use DateTime::Format::HTTP;
use Date::Utility;
use BOM::Platform::Runtime;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Context qw(request);

with 'App::Base::Script';
with 'BOM::Utility::Logging';

sub options {
    return [{
            name          => 'start_date',
            display       => 'start_date=<start_date>',
            documentation => 'start date in <yyyy-mm-dd>, default to beginning of last month',
            option_type   => 'string',
        },
        {
            name          => 'end_date',
            display       => 'end_date=<end_date>',
            documentation => 'end date in <yyyy-mm-dd>, default to end of last month',
            option_type   => 'string',
        },
    ];
}

sub script_run {
    my $self = shift;

    my $logger = get_logger();

    my $localhost = BOM::Platform::Runtime->instance->hosts->localhost;
    if (not $localhost->has_role('master_live_server')) {
        $self->error("$0 should only run on master live server, not [" . $localhost->canonical_name . "]");
    }

    my $start_date = $self->start_date;
    my $end_date   = $self->end_date;

    if ($self->getOption('start_date')) {
        $start_date = DateTime::Format::HTTP->parse_datetime($self->getOption('start_date'))->truncate(to => 'month');

        if ($self->getOption('end_date')) {
            my $datetime = DateTime::Format::HTTP->parse_datetime($self->getOption('end_date'))->truncate(to => 'month');

            $end_date = DateTime->last_day_of_month(
                year  => $datetime->year,
                month => $datetime->month,
                day   => $datetime->day
            );

            # end date should be > start date
            if ($end_date->subtract_datetime($start_date)->is_negative) {
                $self->error('end_date[' . $end_date->ymd . '] should be > start_date[' . $start_date->ymd . ']');
            }
        } else {
            $end_date = DateTime->last_day_of_month(
                year  => $start_date->year,
                month => $start_date->month,
                day   => $start_date->day
            );
        }
    }

    $logger->info('Myaffiliate Commission Calculation: start_date[' . $start_date->ymd . '], end_date[' . $end_date . ']');

    my $dbh = BOM::Database::ClientDB->new({
            broker_code => 'FOG',
            operation   => 'collector',
        })->db->dbh;

    my $calc_commission_sth = $dbh->prepare(
        qq{
            SELECT * FROM data_collection.calculate_affiliate_commission(?,?)
        }
    );

    my $check_duplicate_sth = $dbh->prepare(
        qq{
            SELECT count(*) FROM data_collection.myaffiliates_commission WHERE effective_date = ?
        }
    );

    my $end_date_loop;
    while ($end_date->subtract_datetime($start_date)->is_positive) {
        $end_date_loop = DateTime->last_day_of_month(
            year  => $start_date->year,
            month => $start_date->month,
            day   => $start_date->day
        );

        $logger->info('Check for duplicate, month[' . $start_date->ymd . ']');
        $check_duplicate_sth->execute($start_date->ymd);
        my @count = $check_duplicate_sth->fetchrow_array();
        if ($count[0] > 0) {
            $logger->warn('Already calculated for month[' . $start_date->ymd . "], SKIPPING...");
            $start_date->add(months => 1);
            next;
        }

        eval {
            $logger->info('Calculating affiliate commission for month[' . $start_date->ymd . ']');

            $calc_commission_sth->execute($start_date->ymd, $end_date_loop->ymd);
            @count = $calc_commission_sth->fetchrow_array();

            $logger->info('Affiliate commission for month[' . $start_date->ymd . "], inserted $count[0] rows to db");
        };
        if ($@) {
            $logger->error('Failed Calculating affiliate commission, month[' . $start_date->ymd . "], error[$@]");
            last;
        }

        $start_date->add(months => 1);
    }

    return 0;
}

has start_date => (
    is      => 'ro',
    isa     => 'DateTime',
    lazy    => 1,
    default => sub {
        return DateTime->now->subtract(months => 1)->truncate(to => 'month');
    },
);

has 'end_date' => (
    is      => 'ro',
    isa     => 'DateTime',
    default => sub {
        my $self = shift;
        return DateTime->last_day_of_month(
            year  => $self->start_date->year,
            month => $self->start_date->month,
            day   => $self->start_date->day
        );
    },
);

sub documentation {
    return qq{
This script monthly affiliate's commission & insert into data_collection.myaffiliates_commission table
    };
}

sub cli_template {
    return $0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package main;
use strict;

exit BOM::System::Script::MyaffiliateCommission->new->run;

