#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 9);
use Test::Exception;
use Test::Warn qw(warning_like);
use Test::NoWarnings;
use Test::MockTime qw( set_absolute_time restore_time );
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use Date::Utility;

use BOM::MarketData::Parser::Bloomberg::CSVParser::CorporateAction;

my $bbdl                  = 'BOM::MarketData::Parser::Bloomberg::CSVParser::CorporateAction';
my $dir                   = '/home/git/regentmarkets/bom/t/data/bbdl/corporate_actions';
my $corporate_action_time = Date::Utility->new('2013-08-13');
set_absolute_time($corporate_action_time->epoch);

subtest 'R-code 300' => sub {
    plan tests => 2;
    lives_ok {
        my $corp = $bbdl->new;
        ok !$corp->process_data($dir . '/r_code_300.csv'), 'corporate actions with r-code 300 is skipped';
    }
    'skipping r-code 300';
};

subtest 'stock dividend' => sub {
    plan tests => 8;

    lives_ok {
        my $corp = $bbdl->new;
        my %actions;
        ok %actions = $corp->process_data($dir . '/stock_dividend.csv'), 'correctly process stock dividend';
        my $first = $actions{UKDGE}->{80004829};
        is $first->{description},    'Stock Dividend (N.A.)', 'verify action description';
        is $first->{flag},           'N',                     'new action';
        is $first->{modifier},       'divide',                'divide barrier with the adjustment factor stock dividend';
        is $first->{value},          1.02,                    'amount to adjust';
        is $first->{type},           'DVD_STOCK',             'type';
        is $first->{effective_date}, '14-Aug-13',             'effective_date';
    }
    'stock dividend';

};

subtest 'stock split' => sub {
    plan tests => 8;
    lives_ok {
        my $corp = $bbdl->new;
        my %actions;
        ok %actions = $corp->process_data($dir . '/stock_split.csv'), 'correctly process stock split';
        my $first = $actions{UKDGE}->{80004829};
        is $first->{description},    'Stock Split (3 for 2)', 'verify action description';
        is $first->{flag},           'N',                     'new action';
        is $first->{modifier},       'divide',                'divide barrier with adjustment factor for stock split';
        is $first->{value},          1.500,                   'amount to adjust';
        is $first->{type},           'STOCK_SPLT',            'type';
        is $first->{effective_date}, '14-Aug-13',             'effective_date';
    }
    'stock split';
};

subtest 'spin off' => sub {
    plan tests => 8;
    lives_ok {
        my $corp = $bbdl->new;
        my %actions;
        ok %actions = $corp->process_data($dir . '/spin_off.csv'), 'correctly process spin off';
        my $first = $actions{UKDGE}->{80004829};
        is $first->{description},    'Spin-Off (1 per 1)', 'verify action description';
        is $first->{flag},           'N',                  'new action';
        is $first->{monitor},        1,                    'monitor flag is on for Spin-Off';
        is $first->{type},           'SPIN',               'type';
        is $first->{effective_date}, '14-Aug-13',          'effective_date';
        ok defined $first->{monitor_date}, 'suspension date is recorded';
    }
    'spin off';
};

subtest 'rights offering' => sub {
    plan tests => 8;
    lives_ok {
        my $corp = $bbdl->new;
        my %actions;
        ok %actions = $corp->process_data($dir . '/rights_offering.csv'), 'correctly process rights offering';
        my $first = $actions{UKDGE}->{80004829};
        is $first->{description},    'Rights Offering (1 per 1)', 'verify action description';
        is $first->{flag},           'N',                         'new action';
        is $first->{monitor},        1,                           'monitor flag is on for rights offering';
        is $first->{type},           'RIGHTS_OFFER',              'type';
        is $first->{effective_date}, '14-Aug-13',                 'effective_date';
        ok defined $first->{monitor_date}, 'suspension date is recorded';
    }
    'rights offering';
};

subtest 'sanity checks' => sub {
    plan tests => 2;
    lives_ok {
        my $corp = $bbdl->new;
        my %actions;
        warning_like {
            $corp->process_data($dir . '/sanity_check.csv');
        }
        [
            qr/Adjustment date\[13-Aug-13\] != Effective date\[14-Aug-13\]/,
            qr/CP_ADJ is != 1\+\(CP_AMT\/100\) in DVD stock/,
            qr/CP_RATIO\[1\.51\] != CP_ADJ\[1\.5\]/,
            qr/Errorneous corporate actions data/
        ];
    }
    'sanity checks';
};

subtest 'skipping ignore actions' => sub {
    plan tests => 2;
    lives_ok {
        my $corp = $bbdl->new;
        ok !$corp->process_data($dir . '/ignore.csv'), 'corporate actions in ignored list  is skipped';
    }
    'ignore';
};

subtest 'skipping old actions' => sub {
    plan tests => 2;
    lives_ok {
        my $corp = $bbdl->new;
        ok !$corp->process_data($dir . '/old_actions.csv'), 'corporate action with old effective date is skipped';
    }
    'skipping old dated corporate actions';
};
