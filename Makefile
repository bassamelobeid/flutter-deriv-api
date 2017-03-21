CURRENT_BRANCH_SAFE=$(shell git rev-parse --abbrev-ref HEAD | sed 's|/|_|g')

default:
	@echo "You must specify target. The following targets available:"
	@echo "  tidy         - Run perltidy"

tidy:
	find . -name '*.p?.bak' -delete
	find . -name '*.p[lm]' -o -name '*.cgi' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

unit_test:
	/etc/rmg/bin/prove --timer -l -I./t -r --exec '/etc/rmg/bin/perl -MTest::FailWarnings=-allow_deps,1' t/

i18n:
	xgettext.pl -P haml=haml -P perl=pl,pm -P tt2=tt,tt2 \
		--output=messages.pot --output-dir=/home/git/binary-com/translations-websockets-api/src/locales   --directory=/home/git/regentmarkets/bom-backoffice/   --directory=/home/git/regentmarkets/bom-platform/ --directory=/home/git/regentmarkets/bom/ --directory=/home/git/regentmarkets/binary-websocket-api/ --directory=/home/git/regentmarkets/bom-rpc/ --directory=/home/git/regentmarkets/bom-oauth/ --directory=/home/git/regentmarkets/bom-epg/ --directory=/home/git/regentmarkets/bom-pricing/ --directory=/home/git/regentmarkets/bom-transaction/
	perl -I /home/git/regentmarkets/bom-platform/lib /home/git/regentmarkets/bom-backoffice/bin/extra_translations.pl  /home/git/binary-com/translations-websockets-api/src/locales/messages.pot
	for i in $(shell ls /home/git/binary-com/translations-websockets-api/src/locales/*.po); do \
		msgmerge --previous --backup none --no-wrap --update $$i /home/git/binary-com/translations-websockets-api/src/locales/messages.pot ; \
	done
	msgmerge --previous --backup none --no-wrap --update  /home/git/binary-com/translations-websockets-api/src/en.po  /home/git/binary-com/translations-websockets-api/src/locales/messages.pot
	perl -pi -e 's/Content-Type: text\/plain; charset=CHARSET/Content-Type: text\/plain; charset=UTF-8/'  /home/git/binary-com/translations-websockets-api/src/locales/messages.pot
	perl -ni -e  'print unless m/(^#:|^#\.)/'  /home/git/binary-com/translations-websockets-api/src/en.po
	for i in $(shell ls /home/git/binary-com/translations-websockets-api/src/locales/*.po*); do \
		perl -ni -e  'print unless m/(^#:|^#\.)/'  $$i ; \
	done

