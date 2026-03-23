FROM ghcr.io/cirruslabs/flutter:stable AS builder

WORKDIR /app

# Copy project files
COPY pubspec.yaml ./

# Bootstrap web platform support (idempotent, won't overwrite lib/)
RUN flutter config --enable-web && \
    flutter create --platforms=web . --project-name=ondes_app 2>&1 || true

RUN flutter pub get

# Copy rest of source
COPY . .

RUN flutter pub get && flutter build web --release

# ── Serve with nginx ──────────────────────────────────────────────────────────
FROM nginx:alpine

COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
