package BOM::Database::Model::Constants;

use warnings;
use strict;

use Readonly;

Readonly our $DEPOSIT    => "deposit";
Readonly our $WITHDRAWAL => "withdrawal";
Readonly our $BUY        => "buy";
Readonly our $SELL       => "sell";
Readonly our $ADJUSTMENT => "adjustment";

Readonly our $PAYMENT_GATEWAY_BANK_WIRE => 'bank_wire';
Readonly our $PAYMENT_GATEWAY_DATACASH  => 'datacash';

Readonly our $PAYMENT_TYPE_CREDIT_DEBIT_CARD => 'credit_debit_card';
Readonly our $PAYMENT_TYPE_FREE_GIFT         => 'free_gift';

Readonly our $BET_CLASS_LEGACY_BET       => 'legacy_bet';
Readonly our $BET_CLASS_RANGE_BET        => 'range_bet';
Readonly our $BET_CLASS_HIGHER_LOWER_BET => 'higher_lower_bet';
Readonly our $BET_CLASS_TOUCH_BET        => 'touch_bet';
Readonly our $BET_CLASS_DIGIT_BET        => 'digit_bet';
Readonly our $BET_CLASS_SPREAD_BET       => 'spread_bet';

# Constant reference to volatile hash
Readonly our $BET_CLASS_TO_TYPE_MAP => {
    'spread_bet' => ['SPREADU', 'SPREADD'],
    'higher_lower_bet' => [
        'FLASHU',      'INTRADU',      'DOUBLEUP',      'FLASHD',         'INTRADD', 'DOUBLEDOWN', 'CALL', 'PUT',
        'CALLE', 'PUTE',
        'TWOFORONEUP', 'TWOFORWARDUP', 'TWOFORONEDOWN', 'TWOFORWARDDOWN', 'ASIANU',  'ASIAND'
    ],

    'legacy_bet' => [
        'CLUB',              'SPREADUP',    'SPREADDOWN',     'DOUBLEDBL',       'BEARSTOP',     'DOUBLECONTRA',
        'DOUBLEONETOUCH',    'BULLSTOP',    'BULLPROFIT',     'BEARPROFIT',      'LIMCALL',      'LIMPUT',
        'CUTCALL',           'CUTPUT',      'KNOCKOUTCALLUP', 'KNOCKOUTPUTDOWN', 'POOL',         'RUNBET_RUNNINGEVEN',
        'RUNBET_RUNNINGODD', 'RUNBET_JACK', 'RUNBET_PLAT',    'OLD_MISC_BET',    'RUNBET_DIGIT', 'RUNBET_TENPCT',
        'RUNBET_DOUBLEUP',   'RUNBET_DOUBLEDOWN',
    ],

    'range_bet' => ['RANGE', 'UPORDOWN', 'EXPIRYRANGE', 'EXPIRYMISS', 'EXPIRYRANGEE', 'EXPIRMISSE'],

    'touch_bet' => ['ONETOUCH',   'NOTOUCH'],
    'digit_bet' => ['DIGITMATCH', 'DIGITDIFF', 'DIGITOVER', 'DIGITUNDER', 'DIGITODD', 'DIGITEVEN'],
};

Readonly our $BET_TYPE_TO_CLASS_MAP => {
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

