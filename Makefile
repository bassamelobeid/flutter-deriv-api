CURRENT_BRANCH_SAFE=$(shell git rev-parse --abbrev-ref HEAD | sed 's|/|_|g')

default:
	@echo "You must specify target. The following targets available:"
	@echo "  tidy         - Run perltidy"

tidy:
	find . -name '*.p?.bak' -delete
	find . -name '*.p[lm]' -o -name '*.cgi' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

unit_test:
	prove --timer -l -I./t -r t/

data_js:
	rm -f statics/javascript/data/*
	if [ ! -d "statics/javascript/data" ]; then mkdir -p statics/javascript/data; fi;
	perl -I ./lib -I ./bin -MGenerateStaticData -e "GenerateStaticData->generate_data_files('statics/javascript/data')"

i18n:
	xgettext.pl -P haml=haml -P perl=pl,pm -P tt2=tt,tt2 \
		--output=messages.pot --output-dir=/home/git/binary-com/translations-websockets-api/src/locales   --directory=/home/git/regentmarkets/bom-backoffice/   --directory=/home/git/regentmarkets/bom-platform/ --directory=/home/git/regentmarkets/bom/ --directory=/home/git/regentmarkets/bom-websocket-api/ --directory=/home/git/regentmarkets/bom-rpc/
	for i in $(shell ls /home/git/binary-com/translations-websockets-api/src/locales/*.po); do \
		msgmerge --previous --backup none --no-wrap --update $$i /home/git/binary-com/translations-websockets-api/src/locales/messages.pot ; \
	done
	msgmerge --previous --backup none --no-wrap --update  /home/git/binary-com/translations-websockets-api/src/en.po  /home/git/binary-com/translations-websockets-api/src/locales/messages.pot
	perl -pi -e 's/Content-Type: text\/plain; charset=CHARSET/Content-Type: text\/plain; charset=UTF-8/'  /home/git/binary-com/translations-websockets-api/src/locales/messages.pot
	sed -i '/^#:.\+:[0-9]\+/d'  /home/git/binary-com/translations-websockets-api/src/en.po
	for i in $(shell ls /home/git/binary-com/translations-websockets-api/src/locales/*.po*); do \
		sed -i '/^#:.\+:[0-9]\+/d'  $$i ; \
	done
