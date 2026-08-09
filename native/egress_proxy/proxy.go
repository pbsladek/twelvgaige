package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	defaultMaxHeaderBytes = 32 * 1024
	defaultHeaderTimeout  = 10 * time.Second
	defaultConnectTimeout = 10 * time.Second
	defaultIdleTimeout    = 5 * time.Minute
)

type config struct {
	Listen           string    `json:"listen"`
	Token            string    `json:"token"`
	AllowedHosts     []string  `json:"allowed_hosts"`
	AllowedPorts     []int     `json:"allowed_ports"`
	ExpiresAt        time.Time `json:"expires_at"`
	MaxConnections   int       `json:"max_connections"`
	MaxHeaderBytes   int       `json:"max_header_bytes,omitempty"`
	HeaderTimeoutMS  int       `json:"header_timeout_ms,omitempty"`
	ConnectTimeoutMS int       `json:"connect_timeout_ms,omitempty"`
	IdleTimeoutMS    int       `json:"idle_timeout_ms,omitempty"`
}

type resolver interface {
	LookupNetIP(context.Context, string, string) ([]netip.Addr, error)
}

type dialFunc func(context.Context, string, string) (net.Conn, error)

type proxy struct {
	config         config
	resolver       resolver
	dial           dialFunc
	allowedPorts   map[int]struct{}
	maxHeaderBytes int
	headerTimeout  time.Duration
	connectTimeout time.Duration
	idleTimeout    time.Duration
	permits        chan struct{}
	auditWriter    io.Writer
	auditMu        sync.Mutex
}

type authorization struct {
	host    string
	port    int
	address netip.Addr
}

type auditRecord struct {
	OccurredAt string `json:"occurred_at"`
	Event      string `json:"event"`
	Host       string `json:"host,omitempty"`
	Port       int    `json:"port,omitempty"`
	Reason     string `json:"reason,omitempty"`
	Detail     string `json:"detail,omitempty"`
}

func newProxy(cfg config) (*proxy, error) {
	if cfg.Listen == "" {
		cfg.Listen = "0.0.0.0:8080"
	}
	if len(cfg.Token) < 32 {
		return nil, errors.New("token must contain at least 32 bytes")
	}
	if len(cfg.AllowedHosts) == 0 {
		return nil, errors.New("at least one allowed host is required")
	}
	if len(cfg.AllowedPorts) == 0 {
		return nil, errors.New("at least one allowed port is required")
	}
	if cfg.ExpiresAt.IsZero() {
		return nil, errors.New("expiry is required")
	}
	if cfg.MaxConnections <= 0 {
		return nil, errors.New("max_connections must be positive")
	}

	hosts := make([]string, 0, len(cfg.AllowedHosts))
	for _, host := range cfg.AllowedHosts {
		normalized, err := normalizePattern(host)
		if err != nil {
			return nil, err
		}
		hosts = append(hosts, normalized)
	}
	cfg.AllowedHosts = uniqueSorted(hosts)

	ports := make(map[int]struct{}, len(cfg.AllowedPorts))
	for _, port := range cfg.AllowedPorts {
		if port < 1 || port > 65535 {
			return nil, fmt.Errorf("invalid allowed port %d", port)
		}
		ports[port] = struct{}{}
	}

	dialer := &net.Dialer{Timeout: durationMS(cfg.ConnectTimeoutMS, defaultConnectTimeout)}
	return &proxy{
		config:         cfg,
		resolver:       net.DefaultResolver,
		dial:           dialer.DialContext,
		allowedPorts:   ports,
		maxHeaderBytes: positiveOr(cfg.MaxHeaderBytes, defaultMaxHeaderBytes),
		headerTimeout:  durationMS(cfg.HeaderTimeoutMS, defaultHeaderTimeout),
		connectTimeout: durationMS(cfg.ConnectTimeoutMS, defaultConnectTimeout),
		idleTimeout:    durationMS(cfg.IdleTimeoutMS, defaultIdleTimeout),
		permits:        make(chan struct{}, cfg.MaxConnections),
		auditWriter:    os.Stdout,
	}, nil
}

func (p *proxy) serve(listener net.Listener) error {
	for {
		connection, err := listener.Accept()
		if err != nil {
			return err
		}

		select {
		case p.permits <- struct{}{}:
			go func() {
				defer func() { <-p.permits }()
				p.serveConnection(connection)
			}()
		default:
			_ = writeResponse(connection, http.StatusServiceUnavailable, "Connection limit reached")
			_ = connection.Close()
			p.audit("connection_denied", "", 0, "connection_limit", "")
		}
	}
}

func (p *proxy) serveConnection(client net.Conn) {
	defer client.Close()
	_ = client.SetReadDeadline(time.Now().Add(p.headerTimeout))

	header, rest, err := readHeader(client, p.maxHeaderBytes)
	if err != nil {
		_ = writeResponse(client, http.StatusBadRequest, "Bad Request")
		p.audit("connection_denied", "", 0, safeReason(err), "")
		return
	}

	request, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(header)))
	if err != nil {
		_ = writeResponse(client, http.StatusBadRequest, "Bad Request")
		p.audit("connection_denied", "", 0, "invalid_request", "")
		return
	}
	defer request.Body.Close()

	if !p.authorizedToken(request.Header.Get("Proxy-Authorization")) {
		_ = writeResponse(client, http.StatusProxyAuthRequired, "Proxy Authentication Required")
		p.audit("connection_denied", "", 0, "invalid_capability", "")
		return
	}
	request.Header.Del("Proxy-Authorization")
	request.Header.Del("Proxy-Connection")

	if !time.Now().Before(p.config.ExpiresAt) {
		_ = writeResponse(client, http.StatusProxyAuthRequired, "Proxy capability expired")
		p.audit("connection_denied", "", 0, "capability_expired", "")
		return
	}

	switch request.Method {
	case http.MethodConnect:
		p.serveConnect(client, request, rest)
	case http.MethodGet, http.MethodHead:
		p.serveHTTP(client, request, rest)
	default:
		_ = writeResponse(client, http.StatusMethodNotAllowed, "Method Not Allowed")
		p.audit("connection_denied", "", 0, "method_denied", "")
	}
}

func (p *proxy) serveConnect(client net.Conn, request *http.Request, rest []byte) {
	host, port, err := splitAuthority(request.Host)
	if err != nil {
		_ = writeResponse(client, http.StatusBadRequest, "Invalid CONNECT authority")
		p.audit("connection_denied", host, port, safeReason(err), "")
		return
	}

	auth, err := p.authorize(host, port)
	if err != nil {
		_ = writeResponse(client, http.StatusForbidden, "Forbidden")
		p.audit("connection_denied", host, port, safeReason(err), "")
		return
	}

	upstream, err := p.connect(auth)
	if err != nil {
		_ = writeResponse(client, http.StatusBadGateway, "Bad Gateway")
		p.audit("connection_failed", host, port, "connect_failed", "")
		return
	}
	defer upstream.Close()

	_ = client.SetReadDeadline(time.Time{})
	_ = client.SetDeadline(time.Now().Add(p.idleTimeout))
	_ = upstream.SetDeadline(time.Now().Add(p.idleTimeout))
	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	if len(rest) > 0 {
		if _, err := upstream.Write(rest); err != nil {
			return
		}
	}
	p.audit("connection_authorized", host, port, "", auth.address.String())
	relay(client, upstream)
}

func (p *proxy) serveHTTP(client net.Conn, request *http.Request, rest []byte) {
	if len(rest) != 0 || request.ContentLength > 0 || len(request.TransferEncoding) != 0 {
		_ = writeResponse(client, http.StatusBadRequest, "Request body denied")
		p.audit("connection_denied", "", 0, "request_body_denied", "")
		return
	}
	if request.URL == nil || !request.URL.IsAbs() || request.URL.Scheme != "http" || request.URL.User != nil {
		_ = writeResponse(client, http.StatusBadRequest, "Absolute HTTP URI required")
		p.audit("connection_denied", "", 0, "absolute_uri_required", "")
		return
	}

	host := request.URL.Hostname()
	port := 80
	if value := request.URL.Port(); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil {
			_ = writeResponse(client, http.StatusBadRequest, "Invalid port")
			return
		}
		port = parsed
	}
	if request.Host != "" && !sameAuthority(request.Host, host, port) {
		_ = writeResponse(client, http.StatusForbidden, "Host mismatch")
		p.audit("connection_denied", host, port, "host_header_mismatch", "")
		return
	}

	auth, err := p.authorize(host, port)
	if err != nil {
		_ = writeResponse(client, http.StatusForbidden, "Forbidden")
		p.audit("connection_denied", host, port, safeReason(err), "")
		return
	}
	upstream, err := p.connect(auth)
	if err != nil {
		_ = writeResponse(client, http.StatusBadGateway, "Bad Gateway")
		return
	}
	defer upstream.Close()

	request.RequestURI = request.URL.RequestURI()
	request.URL.Scheme = ""
	request.URL.Host = ""
	request.Header.Del("Connection")
	request.Close = true
	if err := request.Write(upstream); err != nil {
		return
	}
	_ = client.SetReadDeadline(time.Time{})
	p.audit("connection_authorized", host, port, "", auth.address.String())
	_, _ = io.Copy(client, upstream)
}

func (p *proxy) connect(auth authorization) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), p.connectTimeout)
	defer cancel()
	return p.dial(ctx, "tcp", net.JoinHostPort(auth.address.String(), strconv.Itoa(auth.port)))
}

func (p *proxy) authorize(host string, port int) (authorization, error) {
	host = normalizeHost(host)
	if host == "" || net.ParseIP(host) != nil {
		return authorization{}, errors.New("hostname_required")
	}
	if !p.allowedHost(host) {
		return authorization{}, errors.New("host_denied")
	}
	if _, ok := p.allowedPorts[port]; !ok {
		return authorization{}, errors.New("port_denied")
	}

	ctx, cancel := context.WithTimeout(context.Background(), p.connectTimeout)
	defer cancel()
	addresses, err := p.resolver.LookupNetIP(ctx, "ip", host)
	if err != nil || len(addresses) == 0 {
		return authorization{}, errors.New("dns_failed")
	}
	for _, address := range addresses {
		if !publicAddress(address) {
			return authorization{}, errors.New("private_address_denied")
		}
	}
	sort.Slice(addresses, func(i, j int) bool { return addresses[i].Compare(addresses[j]) < 0 })
	return authorization{host: host, port: port, address: addresses[0].Unmap()}, nil
}

func (p *proxy) allowedHost(host string) bool {
	for _, pattern := range p.config.AllowedHosts {
		if strings.HasPrefix(pattern, "*.") {
			suffix := strings.TrimPrefix(pattern, "*.")
			if host != suffix && strings.HasSuffix(host, "."+suffix) {
				return true
			}
		} else if host == pattern {
			return true
		}
	}
	return false
}

func (p *proxy) authorizedToken(header string) bool {
	var candidate string
	if strings.HasPrefix(header, "Bearer ") {
		candidate = strings.TrimPrefix(header, "Bearer ")
	} else if strings.HasPrefix(header, "Basic ") {
		decoded, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(header, "Basic "))
		if err == nil {
			parts := strings.SplitN(string(decoded), ":", 2)
			if len(parts) == 2 {
				if parts[1] == "" {
					candidate = parts[0]
				} else {
					candidate = parts[1]
				}
			}
		}
	}
	return len(candidate) == len(p.config.Token) &&
		subtle.ConstantTimeCompare([]byte(candidate), []byte(p.config.Token)) == 1
}

func (p *proxy) audit(event, host string, port int, reason, detail string) {
	record := auditRecord{
		OccurredAt: time.Now().UTC().Format(time.RFC3339Nano),
		Event:      event,
		Host:       host,
		Port:       port,
		Reason:     reason,
		Detail:     detail,
	}
	encoded, _ := json.Marshal(record)
	p.auditMu.Lock()
	defer p.auditMu.Unlock()
	_, _ = p.auditWriter.Write(append(encoded, '\n'))
}

func readHeader(connection net.Conn, maximum int) ([]byte, []byte, error) {
	buffer := make([]byte, 0, 4096)
	temporary := make([]byte, 4096)
	for {
		if index := bytes.Index(buffer, []byte("\r\n\r\n")); index >= 0 {
			end := index + 4
			return buffer[:end], buffer[end:], nil
		}
		if len(buffer) >= maximum {
			return nil, nil, errors.New("header_too_large")
		}
		count, err := connection.Read(temporary)
		if count > 0 {
			if len(buffer)+count > maximum {
				return nil, nil, errors.New("header_too_large")
			}
			buffer = append(buffer, temporary[:count]...)
		}
		if err != nil {
			return nil, nil, err
		}
	}
}

func relay(left, right net.Conn) {
	var wait sync.WaitGroup
	wait.Add(2)
	go func() {
		defer wait.Done()
		_, _ = io.Copy(right, left)
		closeWrite(right)
	}()
	go func() {
		defer wait.Done()
		_, _ = io.Copy(left, right)
		closeWrite(left)
	}()
	wait.Wait()
}

func closeWrite(connection net.Conn) {
	if tcp, ok := connection.(*net.TCPConn); ok {
		_ = tcp.CloseWrite()
	}
}

func splitAuthority(value string) (string, int, error) {
	host, portText, err := net.SplitHostPort(value)
	if err != nil {
		return "", 0, errors.New("invalid_authority")
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return host, 0, errors.New("invalid_port")
	}
	return host, port, nil
}

func sameAuthority(value, host string, port int) bool {
	valueHost, valuePort, err := splitAuthorityWithDefault(value, 80)
	return err == nil && normalizeHost(valueHost) == normalizeHost(host) && valuePort == port
}

func splitAuthorityWithDefault(value string, defaultPort int) (string, int, error) {
	if strings.Contains(value, ":") {
		return splitAuthority(value)
	}
	return value, defaultPort, nil
}

func writeResponse(writer io.Writer, status int, reason string) error {
	_, err := fmt.Fprintf(writer,
		"HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
		status, reason)
	return err
}

func publicAddress(address netip.Addr) bool {
	address = address.Unmap()
	if !address.IsValid() || !address.IsGlobalUnicast() || address.IsPrivate() ||
		address.IsLoopback() || address.IsLinkLocalUnicast() || address.IsLinkLocalMulticast() ||
		address.IsMulticast() || address.IsUnspecified() {
		return false
	}
	for _, prefix := range deniedPrefixes {
		if prefix.Contains(address) {
			return false
		}
	}
	return true
}

var deniedPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("2001:db8::/32"),
}

func normalizePattern(pattern string) (string, error) {
	pattern = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(pattern), "."))
	prefix := ""
	if strings.HasPrefix(pattern, "*.") {
		prefix = "*."
		pattern = strings.TrimPrefix(pattern, "*.")
	}
	if !validHostname(pattern) {
		return "", fmt.Errorf("invalid host pattern %q", pattern)
	}
	return prefix + pattern, nil
}

func normalizeHost(host string) string {
	return strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
}

func validHostname(host string) bool {
	if len(host) == 0 || len(host) > 253 || strings.ContainsAny(host, " /:@[]") {
		return false
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, character := range label {
			if (character < 'a' || character > 'z') && (character < '0' || character > '9') && character != '-' {
				return false
			}
		}
	}
	return true
}

func uniqueSorted(values []string) []string {
	set := make(map[string]struct{}, len(values))
	for _, value := range values {
		set[value] = struct{}{}
	}
	result := make([]string, 0, len(set))
	for value := range set {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}

func positiveOr(value, fallback int) int {
	if value > 0 {
		return value
	}
	return fallback
}

func durationMS(value int, fallback time.Duration) time.Duration {
	if value > 0 {
		return time.Duration(value) * time.Millisecond
	}
	return fallback
}

func safeReason(err error) string {
	if err == nil {
		return ""
	}
	reason := err.Error()
	if len(reason) > 64 || strings.ContainsAny(reason, " \t\r\n") {
		return "request_denied"
	}
	return reason
}
