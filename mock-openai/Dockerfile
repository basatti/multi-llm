FROM python:3.12-slim

RUN pip install --no-cache-dir "fastapi>=0.115" "uvicorn>=0.30"

WORKDIR /app
COPY main.py .

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
