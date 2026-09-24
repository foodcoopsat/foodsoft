FROM ruby:2.7.8-bullseye AS builder

# Fix for Debian Bullseye EOL: update apt sources to archive repository
# Bullseye security updates are no longer available, so we disable them
RUN sed -i 's|^deb http://.*debian.org/debian|deb http://archive.debian.org/debian|' /etc/apt/sources.list && \
    sed -i 's|^deb http://.*debian.org/debian-security|# deb http://archive.debian.org/debian-security|' /etc/apt/sources.list && \
    sed -i 's|^deb http://.*debian.org/debian|deb http://archive.debian.org/debian|' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true

RUN supercronicUrl=https://github.com/aptible/supercronic/releases/download/v0.1.3/supercronic-linux-amd64 && \
    supercronicBin=/usr/local/bin/supercronic && \
    supercronicSha1sum=96960ba3207756bb01e6892c978264e5362e117e && \
    curl -fsSL -o "$supercronicBin" "$supercronicUrl" && \
    echo "$supercronicSha1sum  $supercronicBin" | sha1sum -c - && \
    chmod +x "$supercronicBin"

ENV PORT=3000 \
    SMTP_SERVER_PORT=2525 \
    RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=true \
    RAILS_SERVE_STATIC_FILES=true

WORKDIR /usr/src/app

RUN --mount=type=cache,target=/var/cache/apt/ \
    buildDeps='libmagic-dev mariadb-server nodejs' && \
    # Fix for Debian Bullseye EOL: use archive repository
    # Comment out security repo since bullseye-security is no longer available
    sed -i 's|^deb http://archive.debian.org/debian-security|# deb http://archive.debian.org/debian-security|' /etc/apt/sources.list 2>/dev/null || true && \
    apt-get update && \
    apt-get install --no-install-recommends -y $buildDeps 

COPY plugins plugins
COPY config config
COPY config.ru Gemfile Gemfile.lock proc-start Procfile Rakefile VERSION ./
COPY app app
COPY bin bin
COPY db db
COPY lib lib
COPY script script
COPY spec spec
COPY vendor vendor

# install dependencies and generate crontab
RUN echo 'gem: --no-document' >> ~/.gemrc && \
    gem install bundler -v 2.4.22 && \
    bundle config build.nokogiri "--use-system-libraries" && \
    bundle config set --local without 'development test' && \
    bundle config set --local deployment 'true' && \
    bundle install -j 4 && \
    bundle exec whenever >crontab


FROM builder AS compiler

# compile assets with temporary mysql server
RUN export DATABASE_URL=mysql2://localhost/test?encoding=utf8 && \
    export SECRET_KEY_BASE=thisisnotimportantnow && \
    echo "SATRTING mariadb ----------" && \
    /etc/init.d/mariadb start && \
    echo "CREATE temp db ----------" && \
    mariadb -e "CREATE DATABASE test" && \
    cp config/app_config.yml.SAMPLE config/app_config.yml && \
    cp config/cable.yml.SAMPLE config/cable.yml && \
    cp config/database.yml.MySQL_SAMPLE config/database.yml && \
    cp config/storage.yml.SAMPLE config/storage.yml && \
    echo "STARTING rake tasks ------------" && \
    RAILS_ENV=production bundle exec rake db:setup assets:precompile && \
    echo "STOPPING mariadb ------------" && \
    /etc/init.d/mariadb stop && \
    cp -r /usr/local/bundle /bundle

FROM builder AS dev

RUN gem install rubocop-rails rubocop-rspec rubocop-capybara rubocop-factory_bot


FROM builder AS app
COPY --from=compiler /bundle /usr/local/bundle
COPY --from=compiler /usr/src/app/public /usr/src/app/public
COPY --from=compiler /usr/src/app/config /usr/src/app/config

# Make relevant dirs and files writable for app user
RUN mkdir -p tmp storage && \
    chown nobody config/app_config.yml && \
    chown nobody tmp && \
    chown nobody storage

COPY docker-entrypoint.sh ./
RUN apt-get install -y gosu
# Run app as unprivileged user
# USER nobody
ARG REVISION
ARG BUILDTIME
LABEL org.opencontainers.image.created=$BUILDTIME
LABEL org.opencontainers.image.authors=martin@villagefarmer.net
LABEL org.opencontainers.image.url=https://github.com/foodcoops.at/foodsoft
LABEL org.opencontainers.image.source=https://github.com/foodcoops.at/foodsoft
LABEL org.opencontainers.image.revision=$REVISION
LABEL org.opencontainers.image.vendor=IG-FoodCoops
LABEL org.opencontainers.image.licenses=AGPLv3
EXPOSE 3000

VOLUME /usr/src/app/storage

# cleanup, and by default start web process from Procfile
ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["./proc-start", "web"]
