package BOM::Database::Model::Constants;

use strict;
use warnings;

our $DEPOSIT    = "deposit";
our $WITHDRAWAL = "withdrawal";
our $BUY        = "buy";
our $SELL       = "sell";
our $ADJUSTMENT = "adjustment";

our $PAYMENT_GATEWAY_BANK_WIRE = 'bank_wire';
our $PAYMENT_GATEWAY_DATACASH  = 'datacash';

our $PAYMENT_TYPE_CREDIT_DEBIT_CARD = 'credit_debit_card';
our $PAYMENT_TYPE_FREE_GIFT         = 'free_gift';

our $BET_CLASS_LEGACY_BET       = 'legacy_bet';
our $BET_CLASS_RANGE_BET        = 'range_bet';
our $BET_CLASS_HIGHER_LOWER_BET = 'higher_lower_bet';
our $BET_CLASS_TOUCH_BET        = 'touch_bet';
our $BET_CLASS_DIGIT_BET        = 'digit_bet';
our $BET_CLASS_SPREAD_BET       = 'spread_bet';
our $BET_CLASS_LOOKBACK_OPTION  = 'lookback_option';
our $BET_CLASS_RESET_BET        = 'reset_bet';
our $BET_CLASS_CALLPUT_SPREAD   = 'callput_spread';
our $BET_CLASS_HIGH_LOW_TICK    = 'highlowticks';
our $BET_CLASS_RUNS             = 'runs';
our $BET_CLASS_MULTIPLIER       = 'multiplier';

# Constant reference to volatile hash
our $BET_CLASS_TO_TYPE_MAP = {
    'spread_bet'       => ['SPREADU', 'SPREADD'],
    'runs'             => ['RUNLOW',  'RUNHIGH'],
    'higher_lower_bet' => ['CALL',    'PUT', 'CALLE', 'PUTE', 'ASIANU', 'ASIAND'],

    'legacy_bet' => [
        'CLUB',              'SPREADUP',          'SPREADDOWN',     'DOUBLEDBL',       'BEARSTOP',      'DOUBLECONTRA',
        'DOUBLEONETOUCH',    'BULLSTOP',          'BULLPROFIT',     'BEARPROFIT',      'LIMCALL',       'LIMPUT',
        'CUTCALL',           'CUTPUT',            'KNOCKOUTCALLUP', 'KNOCKOUTPUTDOWN', 'POOL',          'RUNBET_RUNNINGEVEN',
        'RUNBET_RUNNINGODD', 'RUNBET_JACK',       'RUNBET_PLAT',    'OLD_MISC_BET',    'RUNBET_DIGIT',  'RUNBET_TENPCT',
        'RUNBET_DOUBLEUP',   'RUNBET_DOUBLEDOWN', 'FLASHU',         'INTRADU',         'DOUBLEUP',      'FLASHD',
        'INTRADD',           'DOUBLEDOWN',        'TWOFORONEUP',    'TWOFORWARDUP',    'TWOFORONEDOWN', 'TWOFORWARDDOWN',
    ],

    'range_bet' => ['RANGE', 'UPORDOWN', 'EXPIRYRANGE', 'EXPIRYMISS', 'EXPIRYRANGEE', 'EXPIRYMISSE'],

    'touch_bet' => ['ONETOUCH',   'NOTOUCH'],
    'digit_bet' => ['DIGITMATCH', 'DIGITDIFF', 'DIGITOVER', 'DIGITUNDER', 'DIGITODD', 'DIGITEVEN'],
    'lookback_option' => ['LBFIXEDCALL', 'LBFIXEDPUT', 'LBFLOATCALL', 'LBFLOATPUT', 'LBHIGHLOW'],
    'reset_bet'       => ['RESETCALL',   'RESETPUT'],
    'callput_spread'  => ['CALLSPREAD',  'PUTSPREAD'],
    'highlowticks'    => ['TICKHIGH',    'TICKLOW'],
    'multiplier'      => ['MULTUP',      'MULTDOWN'],
    'INVALID'         => ['INVALID'],
};

our $BET_TYPE_TO_CLASS_MAP = {
    map {
        my $k = $_;
        map { $_ => $k } @{$BET_CLASS_TO_TYPE_MAP->{$k}};
    } keys %$BET_CLASS_TO_TYPE_MAP
};

1;

=head1 NAME

BOM::Database::Model::Constants

=head1 DESCRIPTION

This is a class to accumulate the constant related to models. Using these types of constants will reduce the risk of typo mistakes.

=head1 SYNOPSIS

    print $BOM::Database::Model::Constants::DEPOSIT;

=head1 VERSION

0.1

=head1 AUTHOR

RMG Company

=cut

