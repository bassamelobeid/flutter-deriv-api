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

package BOM::Platform::Untaint::spot;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9]+\.?[0-9]*)$/;

package BOM::Platform::Untaint::exchange;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(\w+)$/;

package BOM::Platform::Untaint::comment;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(.*)$/;

package BOM::Platform::Untaint::currency;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([A-Z]{3})$/;

package BOM::Platform::Untaint::login_id;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([A-Z]{2,4}[0-9]{4,5})$/;

package BOM::Platform::Untaint::stop_type;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(point|dollar)$/;

package BOM::Platform::Untaint::market;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(forex|indices|stocks|volidx|commodities|sectors|smarties)$/;

package BOM::Platform::Untaint::submarket;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(\w+)$/;

package BOM::Platform::Untaint::category;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(digits|callput|staysinout|endsinout|touchnotouch|asian)$/;

package BOM::Platform::Untaint::bet_type;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(\w+)$/;

package BOM::Platform::Untaint::form_name;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(risefall|digits|asian|higherlower|touchnotouch|staysinout|endsinout|evenodd|overunder|spreads)$/;

package BOM::Platform::Untaint::prediction;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(rises|falls|higher|lower|touches|doesnottouch|between|outside|matches|differs|spreadup|spreaddown)$/;

package BOM::Platform::Untaint::underlying_symbol;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(\w+)$/;

package BOM::Platform::Untaint::duration_unit;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([dhmst]{1})$/;

package BOM::Platform::Untaint::duration;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9]+[dhmst]{1})$/;

package BOM::Platform::Untaint::expiry;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9]{1,2}\-\w{3}\-[0-9]{2}|[0-9]+)$/;

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

package BOM::Platform::Untaint::language;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(\w+)$/;

package BOM::Platform::Untaint::barrier_type;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(relative|absolute)$/;

package BOM::Platform::Untaint::multiple_loginid_separated_by_newline;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([A-Za-z\d\n\s]+)$/;

package BOM::Platform::Untaint::word;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^(\w+)$/;

package BOM::Platform::Untaint::myaffiliates_token;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([\w-]{32})$/;

package BOM::Platform::Untaint::surface_date;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$/;

package BOM::Platform::Untaint::surface_cutoff;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([\w|\s]+\s+[0-9]{2}:[0-9]{2})$/;

package BOM::Platform::Untaint::alphanumeric;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([A-Za-z0-9_]+)$/;

package BOM::Platform::Untaint::password;
use base 'CGI::Untaint::object';
use constant _untaint_re => qr/^([ -~]+)$/;

1;
