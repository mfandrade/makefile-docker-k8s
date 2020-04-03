FROM golang:1.7 AS compiler
WORKDIR /tmp
COPY hello.go .
RUN go build hello.go

FROM scratch
COPY --from=compiler /tmp/hello /
ENTRYPOINT ["/hello"]
