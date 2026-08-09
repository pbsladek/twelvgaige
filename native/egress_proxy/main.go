package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	configPath := flag.String("config", "/run/twelvgaige/egress.json", "path to the immutable session egress configuration")
	flag.Parse()

	config, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load egress configuration: %v", err)
	}

	proxy, err := newProxy(config)
	if err != nil {
		log.Fatalf("validate egress configuration: %v", err)
	}

	listener, err := net.Listen("tcp4", config.Listen)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()

	proxy.audit("proxy_started", "", 0, "", listener.Addr().String())
	if err := proxy.serve(listener); err != nil && !errors.Is(err, net.ErrClosed) {
		log.Fatalf("serve: %v", err)
	}
}

func loadConfig(path string) (config, error) {
	file, err := os.Open(path)
	if err != nil {
		return config{}, err
	}
	defer file.Close()

	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()

	var cfg config
	if err := decoder.Decode(&cfg); err != nil {
		return config{}, err
	}

	if decoder.More() {
		return config{}, fmt.Errorf("configuration contains trailing JSON values")
	}
	return cfg, nil
}
