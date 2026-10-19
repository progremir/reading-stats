FROM python:3.12-slim
RUN pip install --no-cache-dir tzdata
WORKDIR /app
COPY server.py index.html login.html ./
ENV PYTHONUNBUFFERED=1
CMD ["python", "server.py"]
