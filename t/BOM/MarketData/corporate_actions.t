#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 10;
use Test::Exception;
use Test::NoWarnings;
use Date::Utility;

use BOM::System::Chronicle;
use Quant::Framework::CorporateAction;
use Quant::Framework::Utils::Test;

is(Quant::Framework::CorporateAction->new(symbol => 'FPGZ',
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer())->document, undef, 'document is not present');

my $old_date = Date::Utility->new()->minus_time_interval("15m");
my $int = Quant::Framework::Utils::Test::create_doc('corporate_action', {
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        symbol        => 'QWER',
        actions       => {
            "62799500" => {
                "monitor_date" => "2014-02-07T06:00:07Z",
                "type" => "ACQUIS",
                "monitor" => 1,
                "description" =>  "Acquisition",
                "effective_date" =>  "15-Jul-14",
                "flag" => "N"
            },
        },
        recorded_date => $old_date,
    }
);

ok $int->save, 'save without error';

lives_ok {
    my $new = Quant::Framework::CorporateAction->new(symbol => 'QWER',
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer());
    ok $new->document;
    is $new->document->{actions}->{62799500}->{type}, "ACQUIS";
    is $new->document->{actions}->{62799500}->{effective_date}, "15-Jul-14";
} 'successfully retrieved saved document';

lives_ok {
    my $int = Quant::Framework::Utils::Test::create_doc('corporate_action', {
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            symbol        => 'QWER',
            actions       => {
                "32799500" => {
                    "monitor_date" => "2015-02-07T06:00:07Z",
                    "type" => "DIV",
                    "monitor" => 1,
                    "description" =>  "Divided Stocks",
                    "effective_date" =>  "15-Jul-15",
                    "flag" => "N"
                },
            }
        }
    );

    ok $int->save, 'save again without error';

    my $old_corp_action = Quant::Framework::CorporateAction->new(
        symbol      => 'QWER',
        for_date    => $old_date,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer());

    is $old_corp_action->document->{actions}->{62799500}->{type}, "ACQUIS";
} 'successfully reads older corporate actions';
