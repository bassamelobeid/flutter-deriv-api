FROM squidfunk/mkdocs-material

RUN pip install neoteroi-mkdocs
RUN pip install mkdocs-glightbox
RUN pip install json-schema-for-humans

RUN generate-schema-doc --config template_name=md --config with_footer=false api/person/schema/ api/
