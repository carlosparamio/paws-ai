# syntax=docker/dockerfile:1

ARG RUBY_VERSION=3.4

FROM ruby:${RUBY_VERSION}-alpine AS gems

WORKDIR /app

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=test

RUN apk add --no-cache build-base ca-certificates

COPY Gemfile Gemfile.lock ./

RUN gem install bundler -v 2.7.2 \
    && bundle config set without "${BUNDLE_WITHOUT}" \
    && bundle install --jobs 4 --retry 3 \
    && rm -rf /usr/local/bundle/cache /usr/local/bundle/ruby/*/cache

FROM ruby:${RUBY_VERSION}-alpine

WORKDIR /app

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=test

RUN apk add --no-cache ca-certificates \
    && addgroup -S paws \
    && adduser -S -G paws paws \
    && mkdir -p /app/cache

COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock ./
COPY bin/ ./bin/
COPY lib/ ./lib/
COPY web/ ./web/
# Bundle the "El Espía" example game so the image can boot into a working
# snapshot. The .dockerignore rules whitelist only `games/espia*`.
COPY games/ ./games/

RUN chmod +x bin/web \
    && chown -R paws:paws /app /usr/local/bundle

USER paws

EXPOSE 4567

ENTRYPOINT ["bundle", "exec", "bin/web", "--bind", "0.0.0.0", "--port", "4567"]
