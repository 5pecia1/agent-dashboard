FROM mcr.microsoft.com/devcontainers/base:noble@sha256:7ee7da33a68d997971660d91ecc8372e55a38a777c3c6bd6808daf91928052db
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash build-essential ca-certificates clang cmake curl desktop-file-utils file git libgtk-3-dev liblzma-dev libssl-dev libstdc++-12-dev ninja-build pkg-config procps python3 squashfs-tools unzip xauth xvfb xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) arch=x64; checksum=c98423c8470d6dc416d9f7036d0646d8ef5ae92ad9186907f8fcc84cbe7db4ea ;; \
      arm64) arch=arm64; checksum=0ef0a778eaa8599f3e90a8a0979c9fc3f79922cafb5fa6d39f366d974da33bba ;; \
      *) echo "Unsupported Devcontainer architecture" >&2; exit 1 ;; \
    esac; \
    curl --fail --location --retry 3 "https://github.com/jdx/mise/releases/download/v2026.9.1/mise-v2026.9.1-linux-$arch" -o /usr/local/bin/mise; \
    printf '%s  /usr/local/bin/mise\n' "$checksum" | sha256sum --check --strict; \
    chmod 0755 /usr/local/bin/mise
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_CONFIG_DIR=/opt/mise/config \
    PATH=/opt/mise/shims:$PATH \
    PYTHONDONTWRITEBYTECODE=1
RUN python3 -c 'import sys; assert sys.version_info >= (3, 11)' && mise --version
ENV MISE_TRUSTED_CONFIG_PATHS=/opt/mise/config \
    MISE_YES=1
RUN mkdir -p /opt/mise/config && printf '[tools]\n' > /opt/mise/config/config.toml
RUN mise install --yes flutter@3.44.0 && printf '%s\n' '"flutter" = "3.44.0"' >> /opt/mise/config/config.toml && mise reshim
RUN mise install --yes python@3.13.9 && printf '%s\n' '"python" = "3.13.9"' >> /opt/mise/config/config.toml && mise reshim
RUN mise install --yes rust@1.98.1 && printf '%s\n' '"rust" = "1.98.1"' >> /opt/mise/config/config.toml && mise reshim
RUN mise install --yes uv@0.9.16 && printf '%s\n' '"uv" = "0.9.16"' >> /opt/mise/config/config.toml && mise reshim
RUN mise install --yes cargo-binstall@1.23.0 && printf '%s\n' '"cargo-binstall" = "1.23.0"' >> /opt/mise/config/config.toml && mise reshim
RUN mise install --yes cargo:cargo-deny@0.18.3 && printf '%s\n' '"cargo:cargo-deny" = "0.18.3"' >> /opt/mise/config/config.toml && mise reshim
RUN mise install --yes cargo:cargo-expand@1.0.126 && printf '%s\n' '"cargo:cargo-expand" = "1.0.126"' >> /opt/mise/config/config.toml && mise reshim
RUN mise install --yes cargo:flutter_rust_bridge_codegen@2.13.0 && printf '%s\n' '"cargo:flutter_rust_bridge_codegen" = "2.13.0"' >> /opt/mise/config/config.toml && mise reshim
RUN mise install --yes cargo:wasm-pack@0.15.0 && printf '%s\n' '"cargo:wasm-pack" = "0.15.0"' >> /opt/mise/config/config.toml && mise reshim
COPY image-tools.toml /opt/mise/config/config.toml
RUN mise reshim && mise ls --current --json
COPY image-setup.sh /opt/mise/image-setup.sh
RUN bash /opt/mise/image-setup.sh
ENV CHROME_BIN="/opt/sol-browser/chromium"
ENV PLAYWRIGHT_BROWSERS_PATH="/opt/sol-browser/browsers"
ENV SOL_PLATFORM_IMAGE="1"
ENV WEB_CHECK_PYTHON="/opt/sol-browser/bin/python"
