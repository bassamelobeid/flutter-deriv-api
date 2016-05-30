## no critic

=head1 NAME

BOM::Platform::Untaint

=head1 DESCRIPTION

Defines untaint mechanism using CGI::Untaint for several standard inputs.
These inputs can be extracted using

	 my $currency = request()->param_untaint(-as_currency => 'currency' );

The currency value will be extracted from input as long
as it is matched by the regex defined in package BOM::Platform::Untaint::currency
below.

Look up CGI::Untaint on CPAN for more info.

=cut

package BOM::Platform::Untaint::date_yyyymmdd;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])$/;

package BOM::Platform::Untaint::time;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9][0-9]:[0-9][0-9]:?[0-9]?[0-9]?)$/;

package BOM::Platform::Untaint::expiry_type;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(duration|endtime|tick)$/;

package BOM::Platform::Untaint::amount_type;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(payout|stake)$/;

package BOM::Platform::Untaint::ascii_integer;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([+-]?[0-9]+)$/;

package BOM::Platform::Untaint::floating_point;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^((?:-?[0-9]+\.?[0-9]*)|(?:-?\.[0-9]+))$/;

package BOM::Platform::Untaint::price;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9]+\.?[0-9]*)$/;

package BOM::Platform::Untaint::qty;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9]+)$/;

package BOM::Platform::Untaint::comment;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(.*)$/;

package BOM::Platform::Untaint::currency;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([A-Z]{3})$/;

package BOM::Platform::Untaint::stop_type;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(point|dollar)$/;

package BOM::Platform::Untaint::market;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(forex|indices|stocks|volidx|commodities|sectors|smarties)$/;

package BOM::Platform::Untaint::bet_type;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(\w+)$/;

package BOM::Platform::Untaint::form_name;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(risefall|digits|asian|higherlower|touchnotouch|staysinout|endsinout|evenodd|overunder|spreads)$/;

package BOM::Platform::Untaint::underlying_symbol;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(\w+)$/;

package BOM::Platform::Untaint::duration_unit;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([dhmst]{1})$/;

package BOM::Platform::Untaint::duration;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9]+[dhmst]{1})$/;

package BOM::Platform::Untaint::epoch;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9]{1,10})$/;

# not clear on what is really being expected of the following function
package BOM::Platform::Untaint::date_start;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(now|[0-9]{1,10})$/;

package BOM::Platform::Untaint::trade_action;
use base 'CGI::Untaint::object';
use constant _untaint_re =>
    qr/^(bet_page|bet_form|price_box|json_price|barrier_defaults|sell|buy|batch_buy|batch_sell|trading_days|vcal_weights|sell|batch_buy|batch_sell|vol_surface|historical_vol|open_position_values|trading_times)$/;

package BOM::Platform::Untaint::relative_barrier;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([+-]?(?:[0-9]+\.?[0-9]{0,12}|\.[0-9]+)|S\-?[0-9]+P)$/;

package BOM::Platform::Untaint::absolute_barrier;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9]{1,6}\.?[0-9]{0,5}|\.[0-9]{1,5})$/;

sub is_valid {
    my $value = shift->value;
    return ($value > 0);
}

# not going to write the mother of all regexs that would tell
# us exactly if the string was one of our shortcodes or not.
# This simplified one will do.
package BOM::Platform::Untaint::shortcode;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([A-Z_\-\d\.]+)$/;

package BOM::Platform::Untaint::barrier_type;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(relative|absolute)$/;

1;
