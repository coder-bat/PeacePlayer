# syntax=docker/dockerfile:1
#
# The runtime contract is enforced at startup by backend/preflight.py, which calls
# runtime_config.validate() and hard-fails on anything below. Do not relax it:
#
#   * Python must be exactly 3.11 (runtime_config.py: sys.version_info[:2] != (3, 11))
#   * FFMPEG_BIN must resolve to an existing, executable file
#   * DENO_BIN must resolve to an existing, executable file
#   * yt-dlp must be importable
#
# That last one is the easy miss: without deno, yt-dlp cannot solve YouTube's
# JavaScript challenge and every extraction fails at runtime with a confusing
# "unable to extract" rather than a startup error.

FROM python:3.11-slim

# ffmpeg    -> FFMPEG_BIN, audio extraction/transcode
# unzip     -> only used to unpack deno, purged in the same layer
# curl      -> fetches the deno release below
# ca-certs  -> TLS for YouTube
ARG DENO_VERSION=2.1.4
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg unzip curl ca-certificates \
 && case "$TARGETARCH" in \
        amd64) DENO_TARGET=x86_64-unknown-linux-gnu ;; \
        arm64) DENO_TARGET=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-${DENO_TARGET}.zip" -o /tmp/deno.zip \
 && unzip -q /tmp/deno.zip -d /usr/local/bin \
 && chmod 0755 /usr/local/bin/deno \
 && rm -f /tmp/deno.zip \
 && apt-get purge -y unzip \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && ffmpeg -version | head -1 \
 && /usr/local/bin/deno --version | head -1

WORKDIR /app

# Dependencies first so code edits do not invalidate the pip layer.
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Top-level modules only. tests/, data/ and the venvs are excluded by
# .dockerignore; backend/data is 1.3G and must be a bind mount, never a layer.
COPY backend/*.py ./

RUN useradd --create-home --uid 1000 peaceplayer \
 && mkdir -p /data /library \
 && chown -R peaceplayer:peaceplayer /app /data /library

USER peaceplayer

ENV HOST=0.0.0.0 \
    PORT=8181 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    FFMPEG_BIN=/usr/bin/ffmpeg \
    DENO_BIN=/usr/local/bin/deno

EXPOSE 8181

# Assert the running release identity, not merely that a port answers. A server
# left over from a previous deployment answers / happily on the wrong commit,
# which is exactly the failure the launchd/containment design guards against.
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD python -c "import json,os,sys,urllib.request; d=json.load(urllib.request.urlopen('http://127.0.0.1:8181/ready',timeout=5)); sys.exit(0 if d.get('status')=='ready' and d.get('releaseCommit')==os.environ.get('PEACEPLAYER_RELEASE_COMMIT') else 1)"

CMD ["python", "server.py"]
