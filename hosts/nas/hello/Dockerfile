FROM python:3.12-slim

WORKDIR /app
COPY app/ ./

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER app

EXPOSE 8080
CMD ["python", "-u", "main.py"]
