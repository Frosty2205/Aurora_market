FROM python:3.12-slim

WORKDIR /app
RUN pip install --no-cache-dir "psycopg[binary]==3.2.3"
COPY ingesta.py /app/ingesta.py

ENTRYPOINT ["python", "/app/ingesta.py"]
CMD ["resumen"]