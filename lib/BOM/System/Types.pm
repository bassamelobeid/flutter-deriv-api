package BOM::System::Types;

use Moose;
use namespace::autoclean;

=head1 NAME

BOM::System::Types - validated Moose types with BetOnMarkets-specific semantics

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

This module provides validated definition of various datatypes that are prevalent through the BetOnMarkets system. By convention, these types are all prefixed with 'bom_' in order to avoid namespace collisions.

    package MyClass;

    use Moose;

    use BOM::System::Types qw( bom_client_loginid );

    has 'client_loginid' => (
        is  => 'rw',
        isa => 'bom_client_loginid',
    );

    package main;

    my $good = new MyClass( client_loginid => 'CR1234' ); # works
    my $bad = new MyClass( client_loginid => 'fribitz' ); # dies with an explanation


=cut

use POSIX qw( );
use DateTime;
use Data::Validate::IP qw( );
use Math::BigInt;
use Email::Valid;

use MooseX::Types::Moose qw(Int Num Str);
use MooseX::Types -declare => [
    map { "bom_$_" }
        qw(
        big_int
        broker_code
        client_loginid
        currency_code
        email_address
        http_method
        interest_rate_type
        ipv4_host_address
        language_code
        money
        network_protocol
        signal_name
        timestamp
        transaction_type
        cutoff_code
        surface_type
        volatility_source
        bom_time_interval
        )];
use Moose::Util::TypeConstraints;
use Time::Duration::Concise;
use Try::Tiny;

=head1 DEFINED_TYPES

=head2 bom_volatility_source

A valid volatility source from Bloomberg

=cut

subtype 'bom_volatility_source', as Str, where { /^(?:OVDV|vol_points)$/ }, message { "Invalid volatility_source[$_]" };

=head2 bom_broker_code

A valid BetOnMarkets broker code. Many of these are deprecated, but nonetheless valid.

=cut

my $known_broker_codes = {};
foreach (qw(CR MLT MF MX VRTC FOG JP VRTJ)) {
    $known_broker_codes->{$_} = 1;
}
subtype 'bom_broker_code', as Str, where { exists $known_broker_codes->{$_}; }, message { "Unknown broker code [$_]" };

=head2 bom_client_loginid

A valid BetOnMarkets client login ID, of the form broker code + sequence ID, e.g. CR1234 or MLT54321

=cut

subtype 'bom_client_loginid', as Str, where { /^[A-Z]{2,6}\d{3,}$/ }, message { "Invalid client loginid [$_]" };

=head2 bom_currency_code

A valid ISO currency code in the BetOnMarkets system (AUD, EUR, GBP, USD). Note that this does not take into account which currencies are valid in the current broker code or server; it just validates the currency code as one of the four that we know about.

=cut

my @currencies = qw( AUD EUR GBP USD );
subtype 'bom_currency_code', as Str, where { my $regex = '(' . join('|', @currencies) . ')'; /^$regex$/ }, message {
    "Invalid currency $_. Must be one of: " . join(', ', @currencies)
};

=head2 bom_email_address

A valid email address.

=cut

subtype 'bom_email_address', as Str, where { Email::Valid->address(shift) }, message { "Invalid email address $_" };

=head2 bom_http_method

An HTTP method verb; either GET or POST. PUT, HEAD, and DELETE are valid HTTP methods, but are not yet supported by this type.

=cut

subtype 'bom_http_method', as Str, where { /^(GET|POST)$/ }, message { 'Invalid HTTP method, must be GET or POST.' };

=head2 interest_rate_type

A valid interest rate type: implied, market.

=cut

my @interest_rate_types = qw(implied market);
subtype 'bom_interest_rate_type', as Str, where {
    my $regex = '(' . join('|', @interest_rate_types) . ')';
    /^$regex$/
}, message {
    "Invalid interest_rate type $_. Must be one of: " . join(', ', @interest_rate_types)
};

=head2 bom_ipv4_host_address

A valid IPv4 address in four-octet notation (a.b.c.d). This is NOT expected to be a network address, and as such cannot end in .0 (a typical network address) or .255 (a typical broadcast address)

=cut

subtype 'bom_ipv4_host_address', as Str, where {
    Data::Validate::IP::is_ipv4($_) and ($_ eq '0.0.0.0' or not /\.(0|255)$/)
};
message {
    my $ip = defined($_) ? $_ : '';
    "Invalid IP address $ip, must in NNN.NNN.NNN.NNN format."
};

=head2 bom_language_code

A valid ISO-639-1 language which is supported by the BetOnMarkets.com code base

=cut

my @languages = qw( de en es fr id ja pt ru zh );
subtype 'bom_language_code', as Str, where { my $regex = '(' . join('|', @languages) . ')'; /^$regex$/ }, message {
    "Invalid language code $_. Must be one of: " . join(', ', @languages)
};

=head2 bom_money

A valid numeric representation of an amount of money. Can be positive or negative (leading negative sign), and cannot exceed two digits of precision.

=cut

subtype 'bom_money', as Num, where { not /\.\d{3}/ and not /\.$/ }, message { "Invalid money amount $_" };

=head2 bom_network_protocol

A valid service protocol. Unless we get *really* fancy this is always going to be TCP or UDP.

=cut

my @network_protocol_list = qw( tcp udp );
my $network_protocol_regex = '^(' . join('|', @network_protocol_list) . ')$';
subtype 'bom_network_protocol', as Str, where { $_ =~ /$network_protocol_regex/ }, message { "Invalid service protocol $_"; };

=head2 bom_signal_name

A valid POSIX signal name. Not a complete list, but reasonably thorough.

=cut

my @signal_list = qw(
    ABRT ALRM BUS CHLD CLD CONT EMT FPE HUP ILL INFO INT IO IOT
    KILL LOST PIPE POLL PROF PWR QUIT SEGV STOP SYS TERM TRAP
    TSTP TTIN TTOU USR1 USR2 WINCH
);
my $signal_list_regex = '^(' . join('|', @signal_list) . ')$';
subtype 'bom_signal_name', as Str, where { $_ =~ /$signal_list_regex/ }, message { "Invalid signal name $_"; };

subtype 'bom_date_object', as 'Date::Utility';
coerce 'bom_date_object', from 'Str', via { Date::Utility->new($_) };

=head2 bom_timestamp

A valid ISO8601 timestamp, restricted specifically to the YYYY-MM-DDTHH:MI:SS format. Optionally, "Z", "UTC", or "GMT" can be appended to the end. No other time zones are supported.

bom_timestamp can be coerced from C<Date::Utility>

=cut

subtype 'bom_timestamp', as Str, where {
    if (/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|GMT|UTC)?$/) {
        my $date = try {
            DateTime->new(
                year      => $1,
                month     => $2,
                day       => $3,
                hour      => $4,
                minute    => $5,
                second    => $6,
                time_zone => 'GMT'
            );
        };
        return $date ? 1 : 0;
    } else {
        return 0;
    }
}, message {
    "Invalid timestamp $_, please use YYYY-MM-DDTHH:MM:SSZ format";
};
coerce 'bom_timestamp', from 'bom_date_object', via { $_->datetime_iso8601 };

=head2 bom_big_int

A Math::BigInt that is coercable from an integer.

=cut

subtype 'bom_big_int', as 'Math::BigInt';
coerce 'bom_big_int', from Int, via { Math::BigInt->new($_) };

=head2 bom_cutoff_code

A volatility surface cutoff code. Format follows Bloomberg naming conventions.

=cut

subtype 'bom_cutoff_code', as Str, where {
    /^(?:Bangkok|Beijing|Bucharest|Budapest|Colombia|Frankfurt|Hanoi|Istanbul|Jakarta|Kuala Lumpur|London|Manila|Mexico|Moscow|Mumbai|New York|PTAX \(Ask\)|Santiago|Sao Paulo|Seoul|Singapore|Taipei|Taiwan|Tel Aviv|Tokyo|UTC|GMT|Warsaw|Wellington) \d{1,2}:\d{2}$/;
}, message {
    'Invalid cutoff_code [' . $_ . ']';
};

=head2 bom_surface_type

Volatility surface types.

=cut

my @surface_types = qw( delta flat moneyness phased);
subtype 'bom_surface_type', as Str, where {
    my $regex = '(' . join('|', @surface_types) . ')';
    /^$regex$/;
}, message {
    "Invalid surface type $_. Must be one of: " . join(', ', @surface_types);
};

subtype
    'PositiveNum' => as 'Num',
    => where { $_ > 0 } => message { 'Must be positive number: [' . $_ . ']' };

subtype
    'NonNegativeNum' => as 'Num',
    => where { $_ >= 0 } => message { 'Must be non-negative number: [' . $_ . ']' };

subtype 'bom_time_interval', as 'Time::Duration::Concise';

coerce 'bom_time_interval', from 'Str', via { Time::Duration::Concise->new(interval => $_) };

__PACKAGE__->meta->make_immutable;
1;
