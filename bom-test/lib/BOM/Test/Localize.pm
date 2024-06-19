package BOM::Test::Localize;

use strict;
use warnings;
use Test::Most;
use Test::MockModule;
use base qw( Exporter );
use Data::Dumper;

our @EXPORT_OK = qw(is_localized);

=head1 NAME

BOM::Test::Localize

=head1 SYNOPSYS

use BOM::Test::Localize;

$msg = BOM::Platform::Context::localize(['First [_1] and Second [_2]', 'one', 'two']);

$result = is_localized ($msg);
ok($result, 'Message is localized');

$result = is_localized ($msg, 'First one and Second two');
ok($result, 'Localized message is correct');

is ($msg, '<LOC>First one and Second two</LOC>', 'Localization is correct both in form and content');
    
=head1 DESCRIPTION

This module verifies localized messages created by B<BOM::Platform::Context::localize> calls, a subroutine that takes either a single string or a list of scalars (consisting of a template string followed by replacemet args) and uses `Locale::Maketext::maketext` calls for producing actual translations. 
To verify that lopcalized messages are not truncated or concatemated, this module alters the default behavior of B<BOM::Platform::Context::localize> by mocking B<maketext> calls so that each scalar value contained in the input is circled by a I<< <LOC></LOC> >> tag pair in the output; for example:

B<localize('Message')> will return: B<< <LOC>Message</LOC> >>

B<localize(['First [_1] and Second [_2]', localize('one'), localize('two')])> will return: B<< <LOC>First <LOC>one</LOC> and Second <LOC>two</LOC></LOC> >>

The most important subroutine contained in this module is B<is_localized>, which verifies if its input argument is produced by a 'localize' call and has not been truncated or concatemated afterwards. For example the value of $result is TRUE in the following code block:
    $msg = BOM::Platform::Context::localize(['First [_1] and Second [_2]', 'one', 'two']);
    $result = is_localized ($msg);
    ok($result, 'Message is localized');
    
We can also add the normal plain message (as expected to be produced by a normal 'localized' call) as the second arg of the subroutine to verify if we are getting propper content out of localization:
    $result = is_localized ($msg, 'First one and Second two');
    ok($result, 'Localized message is correct');
    
Another possibility is to verify the whole process of localization by checking out the tag placements in a localized message:
    is ($msg, '<LOC>First one and Second two</LOC>', 'Localization is correct both in form and content');

=cut

my $mock_maketext = Test::MockModule->new('Locale::Maketext', no_auto => 1);
$mock_maketext->mock(
    'maketext' => sub {
        my ($handler, @input) = @_;
        return 'Truncated or concatenated localized message: ' . Dumper(@input) unless is_well_formatted(@input);
        my $str = $mock_maketext->original('maketext')->(@_);
        return "<LOC>$str</LOC>";
    });

=head2 is_localized

This method main test subroutine in this package. It validates its input against the rules of proper localization (returned from a direct I<localize> call, not truncated and not concatemated).
The input parameters are as follows:

=over

=item $tagged 

It is the localized string produced by using the current package. As explained above, it should contain well-balanced I<LOC> tag pairs; otherwise it will be rejected as a non-localized string.

=item $plain (optional) 

It is the plain text expected to see after removing the tags. It is the text that we expect to get form a normal I<localize> call.

=back

Return value:

=over 

=item = 1

The input C<$tagged> contains well-balanced tags and, if called with the second parameter C<$plain>, the tagged and plain texts match.

=item = 0

Otherwise.

=back

=cut

sub is_localized {
    my ($tagged, $plain) = @_;
    return 0 if ($tagged !~ m/^<LOC>.*<\/LOC>$/);
    # balance nested start and end markers (we are removing enclosing markers in order to reject concatenated localized strings)
    $tagged = substr($tagged, length('<LOC>'), length($tagged) - length('<LOC></LOC>'));
    my $d = 0;
    while ($tagged =~ m/(<LOC>)|(<\/LOC>)/g) {
        $d += 1 if $1;
        $d -= 1 if $2;
        return 0 if ($d < 0);
    }
    return 0 if ($d != 0);

    if ($plain) {
        $tagged =~ s/(<LOC>)|(<\/LOC>)//g;
        return 0 if ($tagged ne $plain);
    }

    return 1;
}

sub is_well_formatted {
    foreach my $value (@_) {
        if (scalar $value) {
            #any non-localzed scalar or well-structured localzed string is acceptable
            return 0 unless ($value !~ m/(<LOC>)|(<\/LOC>)/ or is_localized($value));
        } elsif (ref($value) eq 'ARRAY') {
            return 0 unless is_well_formatted(@$value);
        }
    }
    return 1;
}

1;
