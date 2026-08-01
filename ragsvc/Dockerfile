FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt pyproject.toml ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 5400
CMD ["python", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "5400"]
