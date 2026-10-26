FROM python:3.12-slim
RUN pip install --no-cache-dir tzdata
WORKDIR /app
COPY server.py auth.py index.html login.html account.html admin.html ./
COPY docs/embroidery.js docs/owl.png ./docs/
ENV PYTHONUNBUFFERED=1
CMD ["python", "server.py"]
