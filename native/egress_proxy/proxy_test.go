package main

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"
)

type resolverFunc func(context.Context, string, string) ([]netip.Addr, error)

func (function resolverFunc) LookupNetIP(ctx context.Context, network, host string) ([]netip.Addr, error) {
	return function(ctx, network, host)
}

func testProxy(t *testing.T) *proxy {
	t.Helper()
	p, err := newProxy(config{
		Token:          strings.Repeat("t", 43),
		AllowedHosts:   []string{"api.example.com", "*.packages.example.com"},
		AllowedPorts:   []int{443},
		ExpiresAt:      time.Now().Add(time.Minute),
		MaxConnections: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	p.auditWriter = io.Discard
	return p
}

func TestAuthorizationPinsPublicDNSAndRejectsPrivateOrUndeclaredTargets(t *testing.T) {
	p := testProxy(t)
	p.resolver = resolverFunc(func(_ context.Context, _, host string) ([]netip.Addr, error) {
		switch host {
		case "api.example.com":
			return []netip.Addr{netip.MustParseAddr("104.18.33.45")}, nil
		case "rebound.packages.example.com":
			return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
		default:
			return []netip.Addr{netip.MustParseAddr("104.18.33.45")}, nil
		}
	})

	auth, err := p.authorize("API.EXAMPLE.COM.", 443)
	if err != nil || auth.address.String() != "104.18.33.45" {
		t.Fatalf("unexpected authorization: %#v, %v", auth, err)
	}
	if _, err := p.authorize("telemetry.example.net", 443); err == nil || err.Error() != "host_denied" {
		t.Fatalf("expected host denial, got %v", err)
	}
	if _, err := p.authorize("api.example.com", 8443); err == nil || err.Error() != "port_denied" {
		t.Fatalf("expected port denial, got %v", err)
	}
	if _, err := p.authorize("rebound.packages.example.com", 443); err == nil || err.Error() != "private_address_denied" {
		t.Fatalf("expected private-address denial, got %v", err)
	}
}

func TestCONNECTRequiresCapabilityAndRelaysToPinnedAddress(t *testing.T) {
	p := testProxy(t)
	p.resolver = resolverFunc(func(_ context.Context, _, _ string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("104.18.33.45")}, nil
	})

	echoListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echoListener.Close()
	go func() {
		connection, acceptErr := echoListener.Accept()
		if acceptErr == nil {
			defer connection.Close()
			_, _ = io.Copy(connection, connection)
		}
	}()

	p.dial = func(_ context.Context, _, address string) (net.Conn, error) {
		if address != "104.18.33.45:443" {
			t.Fatalf("proxy did not dial the pinned address: %s", address)
		}
		return net.Dial("tcp", echoListener.Addr().String())
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() { _ = p.serve(listener) }()

	denied, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.WriteString(denied, "CONNECT api.example.com:443 HTTP/1.1\r\nProxy-Authorization: Bearer wrong\r\n\r\n")
	response, _ := bufio.NewReader(denied).ReadString('\n')
	_ = denied.Close()
	if !strings.Contains(response, "407") {
		t.Fatalf("expected 407, got %q", response)
	}

	allowed, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.WriteString(allowed,
		"CONNECT api.example.com:443 HTTP/1.1\r\nProxy-Authorization: Bearer "+p.config.Token+"\r\n\r\n")
	reader := bufio.NewReader(allowed)
	status, _ := reader.ReadString('\n')
	if !strings.Contains(status, "200") {
		t.Fatalf("expected 200, got %q", status)
	}
	_, _ = reader.ReadString('\n')
	_, _ = io.WriteString(allowed, "bounded tunnel")
	payload := make([]byte, len("bounded tunnel"))
	if _, err := io.ReadFull(reader, payload); err != nil {
		t.Fatal(err)
	}
	if string(payload) != "bounded tunnel" {
		t.Fatalf("unexpected relay payload %q", payload)
	}
	_ = allowed.Close()
}

func TestMappedPrivateAndExpiredCapabilitiesFailClosed(t *testing.T) {
	p := testProxy(t)
	if publicAddress(netip.MustParseAddr("::ffff:127.0.0.1")) {
		t.Fatal("IPv4-mapped loopback was treated as public")
	}
	p.config.ExpiresAt = time.Now().Add(-time.Second)
	if time.Now().Before(p.config.ExpiresAt) {
		t.Fatal("test expiry did not elapse")
	}
}
