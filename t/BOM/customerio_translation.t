use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Exception;

use BOM::Backoffice::Script::CustomerIOTranslation;
use BOM::Platform::Context;

my $cio = BOM::Backoffice::Script::CustomerIOTranslation->new(token => 'x');

subtest 'email parsing' => sub {
    BOM::Config::Runtime->instance->app_config->customerio->transactional_translations(0);
    my $subject = ' {{event.x}}  ';
    cmp_deeply(
        $cio->process_camapign({
                template => {
                    type    => 'email',
                    subject => $subject,
                    body    => '',
                    layout  => '',
                }}
        ),
        {
            strings => [],
            subject => $subject,
            body    => ignore(),
        },
        'only content tag in subject'
    );

    $subject = ' {% if %}  ';
    cmp_deeply(
        $cio->process_camapign({
                template => {
                    type    => 'email',
                    subject => $subject,
                    body    => '',
                    layout  => ''
                }}
        ),
        {
            strings => [],
            subject => $subject,
            body    => ignore(),
        },
        'only liquid tag in subject'
    );

    $subject = 'hello {{event.name | capitalize}}';
    cmp_deeply(
        $cio->process_camapign({
                template => {
                    type    => 'email',
                    subject => $subject,
                    body    => '',
                    layout  => ''
                }}
        ),
        {
            strings => [{
                    id           => ignore(),
                    loc_text     => 'hello [_1]',
                    orig_text    => $subject,
                    placeholders => ['{{event.name | capitalize}}']}
            ],
            subject => re('^\{\{snippets\.\w+?\}\}$'),
            body    => ignore(),
        },
        'tag mixed with content'
    );

    $subject = 'You {%if event.pass %}passed{% else %}failed{% endif %}.';
    cmp_deeply(
        $cio->process_camapign({
                template => {
                    type    => 'email',
                    subject => $subject,
                    body    => '',
                    layout  => ''
                }}
        ),
        {
            strings => [{
                    id           => ignore(),
                    loc_text     => 'You [_1]passed[_2]failed[_3].',
                    orig_text    => $subject,
                    placeholders => ['{%if event.pass %}', '{% else %}', '{% endif %}']}
            ],
            subject => re('^\{\{snippets\.\w+?\}\}$'),
            body    => ignore(),
        },
        'inline liquid tags'
    );

    my $body = '<p>hello <b>{{event.name}}</b></p>';
    cmp_deeply(
        $cio->process_camapign({
                template => {
                    type    => 'email',
                    subject => '',
                    body    => $body,
                    layout  => ''
                }}
        ),
        {
            strings => [{
                    id           => ignore(),
                    loc_text     => 'hello [_1][_2][_3]',
                    orig_text    => 'hello <b>{{event.name}}</b>',
                    placeholders => ['<b>', '{{event.name}}', '</b>']}
            ],
            subject => '',
            body    => re('<p>\{\{snippets\.\w+?\}\}</p>'),
            ,
        },
        'inline tags in body'
    );

    $body = '<loc>visit <i>{{event.url}}</i></loc>';
    cmp_deeply(
        $cio->process_camapign({
                template => {
                    type    => 'email',
                    subject => '',
                    body    => $body,
                    layout  => ''
                }}
        ),
        {
            strings => [{
                    id           => ignore(),
                    loc_text     => 'visit [_1][_2][_3]',
                    orig_text    => 'visit <i>{{event.url}}</i>',
                    placeholders => ['<i>', '{{event.url}}', '</i>']}
            ],
            subject => '',
            body    => re('\{\{snippets\.\w+?\}\}'),
            ,
        },
        '<loc> tags'
    );

    my $res = $cio->process_camapign({
            template => {
                type    => 'email',
                subject => '[spam] hi there',
                body    => 'click [{{event.link}}] here',
                layout  => ''
            }});

    cmp_deeply(
        $res,
        {
            strings => bag({
                    id           => ignore(),
                    loc_text     => '~[spam~] hi there',
                    orig_text    => '[spam] hi there',
                    placeholders => []
                },
                {
                    id           => ignore(),
                    loc_text     => 'click ~[[_1]~] here',
                    orig_text    => 'click [{{event.link}}] here',
                    placeholders => ['{{event.link}}']}
            ),
            subject => re('\{\{snippets\.\w+?\}\}'),
            body    => re('\{\{snippets\.\w+?\}\}'),
        },
        'escaping of square brackets'
    );

    for my $string ($res->{strings}->@*) {
        lives_ok {
            is BOM::Platform::Context::localize($string->{loc_text}, $string->{placeholders}->@*),
                $string->{orig_text}, 'square brackets localized properly'
        } 'localize square brackets had no error';
    }

    cmp_deeply(
        $cio->process_camapign({
                template => {
                    type    => 'push',
                    subject => 'Yo {{event.name}}',
                    body    => '{{event.thing}} happened',
                    layout  => ''
                }}
        ),
        {
            strings => bag({
                    id           => ignore(),
                    loc_text     => 'Yo [_1]',
                    orig_text    => 'Yo {{event.name}}',
                    placeholders => ['{{event.name}}']
                },
                {
                    id           => ignore(),
                    loc_text     => '[_1] happened',
                    orig_text    => '{{event.thing}} happened',
                    placeholders => ['{{event.thing}}']
                },

            ),
            subject => re('\{\{snippets\.\w+?\}\}'),
            body    => re('\{\{snippets\.\w+?\}\}'),
            ,
        },
        'Push notification'
    );

    $body = "<style>ignore this</style><!-- ignore this too -->";
    $res  = $cio->process_camapign({
            template => {
                type    => 'email',
                subject => '',
                body    => $body,
                layout  => ''
            }});
    cmp_deeply $res->{strings}, [], 'ignore tags, no strings found';
    like $res->{body}, qr/ignore this.*?ignore this too/s, 'ignore tags, body unchanged';

    $res = $cio->process_camapign({
            template => {
                type    => 'email',
                subject => '',
                body    => '<p>body</p>',
                layout  => '<p>layout</p>{{content}}'
            }});
    is $res->{strings}->@*, 2, 'all strings found with layout';
    like $res->{body}, qr/(\{\{snippets\.\w+?\}\}.*?){2}/s, 'snippet tags in template and body';

    $body = 'orphan text
    <div>root div
        <div><p>para text</pa></div>
        <div><table><tr><td>table text</td></tr></table></div>
    </div>';
    $res = $cio->process_camapign({
            template => {
                type    => 'email',
                subject => '',
                body    => $body,
                layout  => ''
            }});
    cmp_deeply [map { $_->{loc_text} } $res->{strings}->@*], bag('orphan text', 'root div', 'para text', 'table text'),
        'all strings found in nested structure';

};

subtest 'generate snippet' => sub {
    my $mock_cio = Test::MockModule->new('BOM::Backoffice::Script::CustomerIOTranslation');
    $mock_cio->mock(localize  => sub { die });
    $mock_cio->mock(languages => ['EN', 'CN', 'FR']);

    my $item = {
        id           => 123,
        loc_text     => 'hello [_1]',
        orig_text    => 'hello {{event.name}}',
        placeholders => ['x']};
    is(($cio->generate_snippet($item, 'my campaign', 'snippet_id'))[0], 'hello {{event.name}}', 'original text used when localize dies');

    $mock_cio->mock(localize => sub { BOM::Platform::Context::request->language . ' ' . shift });

    $item->{loc_text} = 'hello';

    is(
        ($cio->generate_snippet($item, 'my campaign'))[0],
        q/{% if event.lang == "CN" %}
CN hello
{% elsif event.lang == "FR" %}
FR hello
{% else %}
EN hello
{% endif %}/,
        'snippet generated successfully'
    );

};

subtest 'update campaigns and snippets' => sub {

    my $mock_cio = Test::MockModule->new('BOM::Backoffice::Script::CustomerIOTranslation');

    my %calls;
    for my $func (qw/update_campaign_action update_snippet delete_snippet/) {
        $mock_cio->redefine($func => sub { $calls{$func}++; 1 });
    }

    my $campaign = {
        id       => 1,
        name     => 'test',
        template => {
            type    => 'email',
            subject => 'hello {{event.name}}',
            body    => '<p>test</p>',
            layout  => ''
        },
        live => {
            type    => 'email',
            subject => '',
            body    => '',
            layout  => ''
        }};
    $mock_cio->redefine(get_campaigns => sub { [$campaign] });

    $mock_cio->redefine(get_snippets => {});
    $cio->update_campaigns_and_snippets;

    cmp_deeply(\%calls, {}, 'no updates if campaign is not updateable');

    $campaign->{updateable} = 1;

    %calls = ();
    $cio->update_campaigns_and_snippets;

    cmp_deeply(
        \%calls,
        {
            update_snippet         => 2,
            update_campaign_action => 1
        },
        'new email with 2 strings'
    );

    $campaign->{template} = {
        type    => 'email',
        subject => '',
        body    => '',
        layout  => ''
    };

    $mock_cio->redefine(get_snippets => {123 => 'blah'});
    %calls = ();
    $cio->update_campaigns_and_snippets;

    cmp_deeply(\%calls, {delete_snippet => 1}, 'unused snippets are deleted');

    # Check if snippets with 'custom_' prefix are not being deleted
    $campaign->{template} = {
        type    => 'email',
        subject => '',
        body    => '',
        layout  => ''
    };

    $mock_cio->redefine(get_snippets => {custom_123 => 'blah'});

    %calls = ();
    $cio->update_campaigns_and_snippets;

    cmp_deeply(\%calls, {}, 'snippets with "custom_" prefix are kept');
};

subtest 'transactional integration' => sub {

    BOM::Config::Runtime->instance->app_config->customerio->transactional_translations(1);

    subtest 'process placehoders' => sub {
        my $item = [
            '{{event.name}}',
            'no liquid tag',
            '{% if event.name %}',
            '{% if event.name  == "ABC" %}',
            '{% if event.name  == "ABC" or event.id != "123" %}',
            '{% if event.name  == "ABC" and event.id != "123" %}',
            '{% if event.org   == "ABC" and event.land != "123" %}',
        ];

        my $expected = [
            '{% if event.name %}{{event.name}}{% else %}{{trigger.name}}{%endif%}',
            'no liquid tag',
            '{% if (event.name  or trigger.name )%}',
            '{% if (event.name  == "ABC"  or trigger.name  == "ABC" )%}',
            '{% if (event.name  == "ABC" or trigger.name  == "ABC") or (event.id != "123"  or trigger.id != "123" )%}',
            '{% if (event.name  == "ABC" or trigger.name  == "ABC") and (event.id != "123"  or trigger.id != "123" )%}',
            '{% if (event.org   == "ABC" or trigger.org   == "ABC") and (event.land != "123"  or trigger.land != "123" )%}',
        ];

        is $cio->_integrate_transactional($item->[$_], "dummy_event"), $expected->[$_], 'expected liqued found' for 0 .. scalar($expected->@*);
    };
};

done_testing;
