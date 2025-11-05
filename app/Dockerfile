FROM --platform=linux/amd64 public.ecr.aws/docker/library/python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080 9090

CMD ["python3", "app.py"]
