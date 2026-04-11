// fakebackend mimics the scry_2 release binary's command interface for use in tests.
//
// Subcommands:
//
//	start  — writes a PID file and exits; if FAKE_BACKEND_CRASH_AFTER=N is set,
//	         sleeps N seconds then removes the PID file before exiting
//	pid    — exits 0 if the PID file exists, exits 1 if it does not
//	stop   — removes the PID file and exits 0
//
// The PID file path is set via the FAKE_BACKEND_PIDFILE environment variable.
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: fakebackend <start|pid|stop>")
		os.Exit(1)
	}

	pidFile := os.Getenv("FAKE_BACKEND_PIDFILE")
	if pidFile == "" {
		fmt.Fprintln(os.Stderr, "fakebackend: FAKE_BACKEND_PIDFILE not set")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "start":
		if err := os.WriteFile(pidFile, []byte("1"), 0644); err != nil {
			fmt.Fprintln(os.Stderr, "fakebackend: write pid file:", err)
			os.Exit(1)
		}
		if after := os.Getenv("FAKE_BACKEND_CRASH_AFTER"); after != "" {
			secs, err := strconv.Atoi(after)
			if err != nil || secs <= 0 {
				fmt.Fprintln(os.Stderr, "fakebackend: invalid FAKE_BACKEND_CRASH_AFTER value")
				os.Exit(1)
			}
			time.Sleep(time.Duration(secs) * time.Second)
			os.Remove(pidFile) //nolint:errcheck
		}

	case "pid":
		if _, err := os.Stat(pidFile); err != nil {
			os.Exit(1)
		}

	case "stop":
		os.Remove(pidFile) //nolint:errcheck

	default:
		fmt.Fprintf(os.Stderr, "fakebackend: unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}
