# Build stage
FROM golang:alpine AS builder

WORKDIR /src

COPY go.mod ./
# Download dependencies if present, or continue
RUN go mod download || true

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-w -s" -o /bin/mock-app .

# Final minimal runtime stage
FROM alpine:3.20

RUN apk --no-cache add ca-certificates

WORKDIR /app
COPY --from=builder /bin/mock-app /app/mock-app

EXPOSE 8080

USER 65534:65534

ENTRYPOINT ["/app/mock-app"]
