FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn

COPY fixtures/servers/paginated_api.py /app/paginated_api.py

EXPOSE 5555

CMD ["python", "paginated_api.py", "5555"]
