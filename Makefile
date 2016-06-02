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
		--output=messages.pot --output-dir=/home/git/translations/binary-static-www2/src/config/locales/ --directory=/home/git/translations/binary-static-www2/src/templates/ --directory=/home/git/regentmarkets/bom-backoffice/   --directory=/home/git/regentmarkets/bom-platform/ --directory=/home/git/regentmarkets/bom/ --directory=/home/git/regentmarkets/bom-websocket-api/ --directory=/home/git/regentmarkets/bom-rpc/
	perl -I /home/git/regentmarkets/bom-platform/lib /home/git/regentmarkets/bom-backoffice/bin/extra_translations.pl  /home/git/translations/binary-static-www2/src/config/locales/messages.pot
	for i in $(shell ls /home/git/translations/binary-static-www2/src/config/locales/*.po); do \
		msgmerge --previous --backup none --no-wrap --update $$i /home/git/translations/binary-static-www2/src/config/locales/messages.pot ; \
	done
	msgmerge --previous --backup none --no-wrap --update /home/git/translations/binary-static-www2/src/config/en.po /home/git/translations/binary-static-www2/src/config/locales/messages.pot ; \
	perl -pi -e 's/Content-Type: text\/plain; charset=CHARSET/Content-Type: text\/plain; charset=UTF-8/' /home/git/translations/binary-static-www2/src/config/locales/messages.pot
