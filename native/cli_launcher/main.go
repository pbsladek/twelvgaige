//go:build darwin || linux

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
)

const (
	fifoEnvironment        = "TWELVGAIGE_INTERRUPT_FIFO"
	readyEnvironment       = "TWELVGAIGE_INTERRUPT_READY"
	payloadEnvironment     = "TWELVGAIGE_CLI_PAYLOAD"
	cleanupFileEnvironment = "TWELVGAIGE_CLI_CLEANUP_FILE"
	cleanupDirEnvironment  = "TWELVGAIGE_CLI_CLEANUP_DIR"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	defer cleanupExternal()

	payload, payloadArgs, err := resolvePayload(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 8
	}

	runtimeDir, err := os.MkdirTemp("", "twelvgaige-cli-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "create CLI runtime directory: %v\n", err)
		return 8
	}
	defer os.RemoveAll(runtimeDir)

	if err := os.Chmod(runtimeDir, 0o700); err != nil {
		fmt.Fprintf(os.Stderr, "secure CLI runtime directory: %v\n", err)
		return 8
	}

	fifoPath := filepath.Join(runtimeDir, "interrupt.fifo")
	readyPath := filepath.Join(runtimeDir, "interrupt.ready")
	if err := syscall.Mkfifo(fifoPath, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "create interrupt FIFO: %v\n", err)
		return 8
	}

	// Keeping one read/write descriptor open makes signal delivery nonblocking
	// even while the BEAM is between polling iterations.
	keepalive, err := os.OpenFile(fifoPath, os.O_RDWR|syscall.O_NONBLOCK, 0o600)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open interrupt FIFO: %v\n", err)
		return 8
	}
	defer func() {
		if keepalive != nil {
			_ = keepalive.Close()
		}
	}()
	var interruptWriter *os.File
	defer func() {
		if interruptWriter != nil {
			_ = interruptWriter.Close()
		}
	}()

	devNull, err := os.Open(os.DevNull)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open null input: %v\n", err)
		return 8
	}
	defer devNull.Close()

	command := exec.Command(payload, payloadArgs...)
	command.Stdin = devNull
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	command.Env = append(os.Environ(), fifoEnvironment+"="+fifoPath, readyEnvironment+"="+readyPath)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	if err := command.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start Twelvgaige payload: %v\n", err)
		return 8
	}

	signals := make(chan os.Signal, 4)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)

	done := make(chan error, 1)
	go func() { done <- command.Wait() }()

	interrupted := false
	for {
		select {
		case childErr := <-done:
			if interrupted {
				return 130
			}
			return exitCode(childErr)

		case received := <-signals:
			debugf("received signal %v", received)
			if received == syscall.SIGTERM {
				_ = syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
				continue
			}

			if ready(readyPath) {
				debugf("attached interrupt is ready")
				if interruptWriter == nil {
					interruptWriter, err = openInterruptWriter(fifoPath)
					if err != nil {
						fmt.Fprintf(os.Stderr, "deliver interrupt: %v\n", err)
						continue
					}
				}
				if keepalive != nil {
					_ = keepalive.Close()
					keepalive = nil
				}
				if err := writeInterrupt(interruptWriter); err != nil {
					fmt.Fprintf(os.Stderr, "deliver interrupt: %v\n", err)
				}
			} else {
				debugf("attached interrupt is not ready")
				interrupted = true
				_ = syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
			}
		}
	}
}

func cleanupExternal() {
	file := os.Getenv(cleanupFileEnvironment)
	dir := os.Getenv(cleanupDirEnvironment)
	if file == "" || dir == "" {
		return
	}

	file = filepath.Clean(file)
	dir = filepath.Clean(dir)
	temp := filepath.Clean(os.TempDir())

	if filepath.Dir(file) != dir || filepath.Dir(dir) != temp ||
		len(filepath.Base(dir)) < len("twelvgaige-release-cli.") ||
		filepath.Base(dir)[:len("twelvgaige-release-cli.")] != "twelvgaige-release-cli." {
		return
	}

	_ = os.Remove(file)
	_ = os.Remove(dir)
}

func openInterruptWriter(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_WRONLY|syscall.O_NONBLOCK, 0o600)
}

func writeInterrupt(fifo *os.File) error {
	_, err := fifo.Write([]byte{'I'})
	return err
}

func debugf(format string, args ...any) {
	if os.Getenv("TWELVGAIGE_INTERRUPT_DEBUG") == "1" {
		fmt.Fprintf(os.Stderr, "[interrupt-launcher] "+format+"\n", args...)
	}
}

func resolvePayload(args []string) (string, []string, error) {
	if len(args) >= 3 && args[0] == "--payload" && args[2] == "--" {
		if args[1] == "" {
			return "", nil, errors.New("payload path is empty")
		}
		return args[1], args[3:], nil
	}

	if payload := os.Getenv(payloadEnvironment); payload != "" {
		return payload, args, nil
	}

	executable, err := os.Executable()
	if err != nil {
		return "", nil, fmt.Errorf("resolve launcher path: %w", err)
	}

	return filepath.Join(filepath.Dir(executable), "twelvgaige.escript"), args, nil
}

func ready(path string) bool {
	stat, err := os.Lstat(path)
	return err == nil && stat.Mode().IsRegular() && stat.Mode().Perm() == 0o600
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}

	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode()
	}

	return 8
}
