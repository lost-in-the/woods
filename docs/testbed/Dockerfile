FROM ruby:3.3.1-slim

ENV LANG=C.UTF-8 \
    BUNDLE_PATH=/bundle \
    BUNDLE_BIN=/bundle/bin \
    BUNDLE_APP_CONFIG=/bundle/.bundle \
    BUNDLE_WITHOUT="production" \
    PATH=/bundle/bin:/app/bin:$PATH

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      libsqlite3-dev \
      libyaml-dev \
      pkg-config \
      curl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN gem install bundler -v 2.5.11 --no-document

WORKDIR /app

EXPOSE 3000

CMD ["bash", "-lc", "bundle install --jobs 4 && bin/rails server -b 0.0.0.0 -p 3000"]
