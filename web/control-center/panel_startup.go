package main

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"syscall"
)

const (
	autoPanelStartPort = 8081
	autoPanelLastPort  = 8090
)

// Bind first; do not use a separate port availability probe (TOCTOU).
// Automatic fallback is permitted only for the initial, absent-settings
// wildcard LAN default. Explicit and saved ports are strictly immutable.
func selectStartupListener(
	address string,
	automatic bool,
	persist func(port int, fallback bool) error,
	bind func(network, address string) (net.Listener, error),
) (net.Listener, int, bool, error) {
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return nil, 0, false, fmt.Errorf("PORT_BIND_FAILED: invalid listener address")
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, 0, false, errors.New("PORT_BIND_FAILED: invalid listener port")
	}
	if !automatic {
		listener, err := bind("tcp", address)
		if err != nil {
			return nil, 0, false, fmt.Errorf("PORT_BIND_FAILED: requested listener unavailable: %w", err)
		}
		return listener, port, false, nil
	}
	if host != "0.0.0.0" || port != autoPanelStartPort || persist == nil {
		return nil, 0, false, errors.New("PANEL_SETTINGS_SAVE_FAILED: unsafe auto-port configuration")
	}
	for candidate := autoPanelStartPort; candidate <= autoPanelLastPort; candidate++ {
		next := net.JoinHostPort(host, strconv.Itoa(candidate))
		listener, err := bind("tcp", next)
		if err != nil {
			if !errors.Is(err, syscall.EADDRINUSE) {
				return nil, 0, false, fmt.Errorf("PORT_BIND_FAILED: automatic listener failed: %w", err)
			}
			if candidate == autoPanelLastPort {
				return nil, 0, false, fmt.Errorf("PORT_BIND_FAILED: no free port in %d-%d", autoPanelStartPort, autoPanelLastPort)
			}
			continue
		}
		fallback := candidate != autoPanelStartPort
		if err := persist(candidate, fallback); err != nil {
			_ = listener.Close()
			return nil, 0, false, fmt.Errorf("PANEL_SETTINGS_SAVE_FAILED: selected port not saved: %w", err)
		}
		return listener, candidate, fallback, nil
	}
	return nil, 0, false, errors.New("PORT_BIND_FAILED: automatic port range exhausted")
}
