CURRENT_BRANCH_SAFE=$(shell git rev-parse --abbrev-ref HEAD | sed 's|/|_|g')

default:
	@echo "You must specify target. The following targets available:"
	@echo "  tidy         - Run perltidy"

tidy:
	find . -name '*.p?.bak' -delete
	find . -name '*.p[lm]' -o -name '*.cgi' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	/etc/rmg/bin/prove --timer -v -l -I./t -r --exec '/etc/rmg/bin/perl -I. -MTest::Warnings' t/BOM

syntax:
	/etc/rmg/bin/prove --timer -v -l -I./t -r --exec '/etc/rmg/bin/perl -I. -MTest::Warnings -MMojo::JSON::MaybeXS' $(wildcard t/0*.t)

localize:
	/etc/rmg/bin/prove --timer -v -l -I./t -r --exec '/etc/rmg/bin/perl -I. -MTest::Warnings' t/localize.t

i18n:
	xgettext.pl \
		-P tt2=tt,tt2 \
		-P generic=html.ep \
		-P perl=pl,pm,cgi \
		-P Locale::Maketext::Extract::Plugin::Null=t,txt,yml \
		--output=messages.pot \
		--output-dir=/home/git/binary-com/translations-websockets-api/src/locales \
		--directory=/home/git/regentmarkets/binary-websocket-api/ \
		--directory=/home/git/regentmarkets/bom/ \
		--directory=/home/git/regentmarkets/bom-backoffice/ \
		--directory=/home/git/regentmarkets/bom-cryptocurrency/ \
		--directory=/home/git/regentmarkets/bom-events/ \
		--directory=/home/git/regentmarkets/bom-oauth/ \
		--directory=/home/git/regentmarkets/bom-platform/ \
		--directory=/home/git/regentmarkets/bom-pricing/ \
		--directory=/home/git/regentmarkets/bom-rpc/lib \
		--directory=/home/git/regentmarkets/bom-transaction/ \
		--directory=/home/git/regentmarkets/cpan/local/lib/perl5/auto/share/dist/Brands/
	perl -I /home/git/regentmarkets/bom-platform/lib /home/git/regentmarkets/bom-backoffice/bin/extra_translations.pl  /home/git/binary-com/translations-websockets-api/src/locales/messages.pot
	for i in $(shell ls /home/git/binary-com/translations-websockets-api/src/locales/*.po); do \
		msgmerge --previous --backup none --no-wrap --update --sort-output $$i /home/git/binary-com/translations-websockets-api/src/locales/messages.pot ; \
	done
	msgmerge --previous --backup none --no-wrap --update --sort-output /home/git/binary-com/translations-websockets-api/src/en.po  /home/git/binary-com/translations-websockets-api/src/locales/messages.pot
	perl -pi -e 's/Content-Type: text\/plain; charset=CHARSET/Content-Type: text\/plain; charset=UTF-8/'  /home/git/binary-com/translations-websockets-api/src/locales/messages.pot
	perl -ni -e  'print unless m/(^#:|^#\.)/'  /home/git/binary-com/translations-websockets-api/src/en.po
	for i in $(shell ls /home/git/binary-com/translations-websockets-api/src/locales/*.po*); do \
		perl -ni -e  'print unless m/(^#:|^#\.)/'  $$i ; \
	done
