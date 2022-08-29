CURRENT_BRANCH_SAFE=$(shell git rev-parse --abbrev-ref HEAD | sed 's|/|_|g')

TESTS=test unit syntax localize

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -lrv --timer
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(TESTS)

tidy:
	find . -name '*.p?.bak' -delete
	find . -name '*.p[lm]' -o -name '*.cgi' -o -name '*.t' | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	@$(PROVE) -I./t t/BOM

syntax_diff:
	@$(PROVE) --norc $$(ls t/*.t | grep -v syntax_all)

syntax:
	@$(PROVE) --norc -I./t $(wildcard t/0*.t)

pod_test:
	@$(PROVE) --norc t/*pod*.t

unit:
	@$(PROVE) -I./t t/unit

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
		--files-from=`find /home/git/regentmarkets/bom-backoffice/ -not -path '*/\.*' -not -path '*\/public\/*'` \
		--directory=/home/git/regentmarkets/bom-cryptocurrency/ \
		--directory=/home/git/regentmarkets/bom-events/ \
		--directory=/home/git/regentmarkets/bom-oauth/ \
		--directory=/home/git/regentmarkets/bom-platform/ \
		--directory=/home/git/regentmarkets/bom-pricing/ \
		--directory=/home/git/regentmarkets/bom-rpc/lib \
		--directory=/home/git/regentmarkets/bom-transaction/ \
		--directory=/home/git/regentmarkets/cpan-private/local/lib/perl5/auto/share/dist/Brands/ \
		--directory=/home/git/regentmarkets/bom-user/lib/
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
