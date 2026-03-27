# Étape 1 : Build Go (multi-stage pour une image finale légère)
FROM golang:1.21 AS builder

WORKDIR /workspace

COPY go.mod go.sum ./
RUN go mod download

COPY api/ api/
COPY internal/ internal/
COPY main.go .

# Compiler en binaire statique (pas de dépendances système)
RUN CGO_ENABLED=0 GOOS=linux go build -o manager .

# Étape 2 : Image finale minimaliste
FROM gcr.io/distroless/static:nonroot

WORKDIR /
COPY --from=builder /workspace/manager .
USER 65532:65532

ENTRYPOINT ["/manager"]
