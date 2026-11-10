FROM node:22-bookworm-slim

WORKDIR /app

COPY package.json ./
RUN npm install --no-audit --no-fund

COPY . .
RUN npm run build

ENV HOST=0.0.0.0
EXPOSE 8080

CMD ["sh", "-c", "npm run preview -- --host 0.0.0.0 --port ${PORT:-8080}"]
