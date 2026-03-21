FROM python:3.11-slim as builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY backend/requirements.txt .
RUN pip install --user --no-cache-dir -r requirements.txt

# Final stage
FROM python:3.11-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1000 viralmusic

# Copy Python packages from builder
COPY --from=builder /root/.local /home/viralmusic/.local
ENV PATH=/home/viralmusic/.local/bin:$PATH

# Set working directory
WORKDIR /app

# Copy application code
COPY --chown=viralmusic:viralmusic backend/*.py ./

# Create library directory
RUN mkdir -p /home/viralmusic/Music/ViralMusic && chown -R viralmusic:viralmusic /home/viralmusic

# Switch to non-root user
USER viralmusic

# Environment variables
ENV HOST=0.0.0.0
ENV PORT=8080
ENV PYTHONUNBUFFERED=1

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1

# Expose port
EXPOSE 8080

# Run server
CMD ["python", "server.py"]
