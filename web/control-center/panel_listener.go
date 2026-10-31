package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"sync"
	"time"
)

// One shared app keeps importer locks/results intact while its TCP port changes.
type panelListeners struct {
	app     *app
	mu      sync.Mutex
	current *http.Server
	servers map[*http.Server]bool
	errors  chan error
}

func newPanelListeners(a *app) *panelListeners {
	return &panelListeners{app: a, servers: map[*http.Server]bool{}, errors: make(chan error, 1)}
}
func (m *panelListeners) replace(listener net.Listener) {
	address := listener.Addr().String()
	server := &http.Server{Handler: m.app.handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 100 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	m.mu.Lock()
	old := m.current
	m.current = server
	m.servers[server] = true
	m.mu.Unlock()
	m.app.liveHost.Store(&address)
	go func() {
		err := server.Serve(listener)
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			select {
			case m.errors <- errors.New("panel listener failed"):
			default:
			}
		}
	}()
	if old != nil {
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = old.Shutdown(ctx)
			_ = old.Close()
			m.mu.Lock()
			delete(m.servers, old)
			m.mu.Unlock()
		}()
	}
}
func (m *panelListeners) shutdown(ctx context.Context) error {
	m.mu.Lock()
	list := make([]*http.Server, 0, len(m.servers))
	for server := range m.servers {
		list = append(list, server)
	}
	m.mu.Unlock()
	var result error
	for _, server := range list {
		if err := server.Shutdown(ctx); err != nil {
			result = err
		}
	}
	return result
}
