FROM python:3.12-alpine

RUN adduser -D -H -u 10001 ratings && mkdir -p /data && chown ratings /data
WORKDIR /app
COPY app.py .

USER ratings
ENV DB_PATH=/data/ratings.db PORT=8000 PYTHONUNBUFFERED=1
VOLUME ["/data"]
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8000/v1/health || exit 1
CMD ["python", "app.py"]
