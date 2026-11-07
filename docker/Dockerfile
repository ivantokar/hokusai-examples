# One image recipe for both backends: docker build --build-arg PRODUCT=vapor-server (or hummingbird-server).
#
# Hokusai 2 needs libvips 8.16 or newer, which Ubuntu 24.04 does not ship (it has 8.15), so the build
# stage compiles libvips from a release tarball and the runtime stage carries only what it links.
# The runtime reports what it can really do at GET /api/capabilities; do not infer codecs from this file.
# Built and smoke-tested for linux/arm64 and linux/amd64 only where CI or a maintainer has run it; see README.

# ---- build ----------------------------------------------------------------
FROM swift:6.2-noble AS build
ARG VIPS_VERSION=8.16.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential meson ninja-build pkg-config curl xz-utils ca-certificates \
      libglib2.0-dev libexpat1-dev libjpeg-turbo8-dev libpng-dev libwebp-dev libtiff-dev \
      libheif-dev libcairo2-dev libpango1.0-dev libfontconfig1-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/libvips/libvips/releases/download/v${VIPS_VERSION}/vips-${VIPS_VERSION}.tar.xz" | tar -xJ -C /tmp \
    && cd "/tmp/vips-${VIPS_VERSION}" \
    && meson setup build --prefix=/opt/vips --libdir=lib --buildtype=release \
         -Dintrospection=disabled -Dmodules=disabled -Dexamples=false \
    && meson install -C build \
    && rm -rf /tmp/vips-*

ENV PKG_CONFIG_PATH=/opt/vips/lib/pkgconfig
# Declared after libvips so building the other backend reuses that (slow) layer.
ARG PRODUCT
WORKDIR /src
# Dependencies first, so editing the web UI does not rebuild them.
COPY recipes/Package.swift recipes/Package.resolved* ./recipes/
COPY ${PRODUCT}/Package.swift ${PRODUCT}/Package.resolved* ./${PRODUCT}/
COPY recipes/Sources ./recipes/Sources
COPY ${PRODUCT}/Sources ./${PRODUCT}/Sources
WORKDIR /src/${PRODUCT}
RUN swift build -c release --product App --static-swift-stdlib

# ---- runtime --------------------------------------------------------------
FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends \
      libglib2.0-0t64 libexpat1 libjpeg-turbo8 libpng16-16t64 libwebp7 libwebpmux3 libwebpdemux2 libtiff6 \
      libheif1 libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libpangoft2-1.0-0 libfontconfig1 \
      libcurl4t64 libxml2 tzdata curl fonts-dejavu-core ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG PRODUCT
COPY --from=build /opt/vips /opt/vips
COPY --from=build /src/${PRODUCT}/.build/release/App /app/server
COPY web /app/web
COPY fixtures /app/fixtures
ENV LD_LIBRARY_PATH=/opt/vips/lib \
    WEB_ROOT=/app/web FIXTURES_ROOT=/app/fixtures HOST=0.0.0.0 PORT=8080
RUN useradd --system --create-home app
USER app
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s CMD curl -fsS http://127.0.0.1:${PORT}/api/backend || exit 1
ENTRYPOINT ["/app/server"]
