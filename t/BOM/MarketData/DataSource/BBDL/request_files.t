#!/usr/bin/perl

use strict;
use warnings;
use File::Remove qw(remove);
use Test::Deep qw(cmp_deeply);
use Test::More (tests => 8);
use Test::NoWarnings;
use Test::Exception;
use Test::Differences;
use File::Temp;
use Test::MockObject::Extends;
use BOM::MarketData::Parser::Bloomberg::RequestFiles;

subtest general => sub {
    my $r;
    lives_ok { $r = BOM::MarketData::Parser::Bloomberg::RequestFiles->new() } 'can create object';

    can_ok($r, 'request_files_dir');
    can_ok($r, 'master_request_files');
    can_ok($r, 'generate_request_files');
    can_ok($r, 'generate_cancel_files');
};

my $dir = File::Temp->newdir;
my $tmp = "$dir";

subtest daily_request_files => sub {
    my $vp = BOM::MarketData::Parser::Bloomberg::RequestFiles->new(
        request_files_dir => $tmp,
    );
    throws_ok { $vp->generate_request_files() } qr/Undefined flag passed during request file generation/, 'throws exception if flag is undefined';
    lives_ok { $vp->generate_request_files('daily') } 'can generate daily request files';

    foreach my $vpfile (@{$vp->master_request_files}) {
        $vpfile = 'd_' . $vpfile;
        ok(-e $tmp . '/' . $vpfile, 'file[' . $vpfile . '] exists');
    }
};

subtest onehost_request_files => sub {
    my $vp = BOM::MarketData::Parser::Bloomberg::RequestFiles->new(
        request_files_dir => $tmp,
    );
    throws_ok { $vp->generate_request_files() } qr/Undefined flag passed during request file generation/, 'throws exception if flag is undefined';
    lives_ok { $vp->generate_request_files('oneshot') } 'can generate oneshot request files';

    foreach my $vpfile (@{$vp->master_request_files}) {
        $vpfile = 'os_' . $vpfile;
        ok(-e $tmp . '/' . $vpfile, 'file[' . $vpfile . '] exists');
    }
};

subtest cancel_files => sub {
    my $cancel = BOM::MarketData::Parser::Bloomberg::RequestFiles->new(
        request_files_dir => $tmp,
    );
    throws_ok { $cancel->generate_cancel_files() } qr/Undefined flag passed during request file generation/, 'throws exception if flag is undefined';
    lives_ok { $cancel->generate_cancel_files('oneshot') } 'can generate oneshot request files';
    foreach my $cancelfile (@{$cancel->master_request_files}) {
        $cancelfile = 'c_' . $cancelfile;
        ok(-e $tmp . '/' . $cancelfile, 'file[' . $cancelfile . '] exists');
    }
};

subtest get_tickerlist => sub {
    plan tests => 5;

    my $r               = BOM::MarketData::Parser::Bloomberg::RequestFiles->new;
    my @expected_asia   = qw(HSCEI JCI HSI NIFTY KOSPI2 N225 AS51 STI BSESENSEX30 NZ50 SZSECOMP SSECOMP);
    my @expected_europe = qw(FCHI N150 BFX TOP40 SX5E ISEQ PSI20 GDAXI FTSEMIB FTSE N100 IBEX35 SSMI OMXS30 AEX);
    my @expected_us     = qw(SPC NDX IXIC DJI SPTSX60);

    cmp_deeply(sort @{$r->get_all_indices_by_region->{asia}},   sort @expected_asia);
    cmp_deeply(sort @{$r->get_all_indices_by_region->{europe}}, sort @expected_europe);
    cmp_deeply(sort @{$r->get_all_indices_by_region->{us}},     sort @expected_us);

    my $all;
    lives_ok { $all = $r->get_all_indices_by_region } 'lives';
    cmp_deeply(sort keys %$all, ('asia', 'europe', 'us'), 'got back all region');
};

subtest request_files_error => sub {
    # invalid ohlc request files
    my $error = BOM::MarketData::Parser::Bloomberg::RequestFiles->new(
        request_files_dir => $tmp,
    );
    $error = Test::MockObject::Extends->new($error);
    $error->mock('_ohlc_request_files', sub { return ['ohlc_error_x.req'] });
    throws_ok { $error->generate_request_files('daily') } qr/Invalid request file/, 'throws error if ohlc request file is invalid';
};

subtest coverage_for_private_methods => sub {
    my $error = BOM::MarketData::Parser::Bloomberg::RequestFiles->new(
        request_files_dir => $tmp,
    );
    $error = Test::MockObject::Extends->new($error);
    lives_ok { $error->_get_vols_template('fxvol_something_OVDV.req', 'OVDV') } 'faulty vol request file';

    lives_ok { $error->_tickerlist_vols({include => 'all', request_time => time}) } 'skip frxBROUSD';
    lives_ok { $error->_get_quanto_template('quantovol.req', 'all') } 'skip frxBROUSD for quanto';

    my $volpoints_error = BOM::MarketData::Parser::Bloomberg::RequestFiles->new(
        request_files_dir => $tmp,
    );

    lives_ok { $volpoints_error->_tickerlist_vols({include => 'all', request_time => undef}) } 'request_time undef';
};
