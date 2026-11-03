FROM python:3.12-slim

WORKDIR /app
RUN pip install --no-cache-dir "streamlit==1.39.0" "psycopg[binary]==3.2.3" "pandas==2.2.3"
COPY app.py /app/app.py

EXPOSE 8501
ENTRYPOINT ["streamlit", "run", "/app/app.py", "--server.port=8501", "--server.address=0.0.0.0", "--server.headless=true", "--browser.gatherUsageStats=false", "--client.toolbarMode=viewer"]