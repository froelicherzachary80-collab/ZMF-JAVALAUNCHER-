FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
ENV PORT=24470
EXPOSE 24470
USER node
CMD ["node", "src/server.js"]
