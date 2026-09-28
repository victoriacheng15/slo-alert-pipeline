package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests processed by method, route, and status code.",
		},
		[]string{"method", "route", "status"},
	)

	httpRequestDurationSeconds = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "Histogram of HTTP request latencies in seconds.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "route"},
	)
)

type ChaosConfig struct {
	ErrorRate float64 `json:"error_rate"` // Probability between 0.0 and 1.0
	LatencyMs int     `json:"latency_ms"` // Artificial delay in milliseconds
}

type Server struct {
	mu          sync.RWMutex
	chaosConfig ChaosConfig
}

func init() {
	prometheus.MustRegister(httpRequestsTotal)
	prometheus.MustRegister(httpRequestDurationSeconds)
}

func (s *Server) getChaosConfig() ChaosConfig {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.chaosConfig
}

func (s *Server) setChaosConfig(cfg ChaosConfig) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cfg.ErrorRate < 0.0 {
		cfg.ErrorRate = 0.0
	} else if cfg.ErrorRate > 1.0 {
		cfg.ErrorRate = 1.0
	}
	s.chaosConfig = cfg
}

type statusResponseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *statusResponseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

func instrument(route string, handler http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		srw := &statusResponseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		handler(srw, r)

		duration := time.Since(start).Seconds()
		httpRequestDurationSeconds.WithLabelValues(r.Method, route).Observe(duration)
		httpRequestsTotal.WithLabelValues(r.Method, route, strconv.Itoa(srw.statusCode)).Inc()
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	server := &Server{
		chaosConfig: ChaosConfig{
			ErrorRate: 0.0,
			LatencyMs: 0,
		},
	}

	mux := http.NewServeMux()

	// Root Directory and Health Probes
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{
  "service": "mock-app",
  "status": "running",
  "endpoints": [
    "/healthz",
    "/metrics",
    "/api/checkout/process",
    "/api/checkout/fail",
    "/api/checkout/slow",
    "/api/inventory/items",
    "/chaos/configure"
  ]
}`))
	})
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})

	// Tenant Checkout: Route-based failure modes
	mux.HandleFunc("/api/checkout/process", instrument("/api/checkout/process", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"success","message":"checkout processed"}`))
	}))

	mux.HandleFunc("/api/checkout/fail", instrument("/api/checkout/fail", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"status":"error","message":"simulated checkout failure"}`))
	}))

	mux.HandleFunc("/api/checkout/slow", instrument("/api/checkout/slow", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"success","message":"slow checkout processed"}`))
	}))

	// Tenant Inventory: Dynamic chaos state controls
	mux.HandleFunc("/api/inventory/items", instrument("/api/inventory/items", func(w http.ResponseWriter, r *http.Request) {
		cfg := server.getChaosConfig()
		if cfg.LatencyMs > 0 {
			time.Sleep(time.Duration(cfg.LatencyMs) * time.Millisecond)
		}

		w.Header().Set("Content-Type", "application/json")
		if cfg.ErrorRate > 0 && rand.Float64() < cfg.ErrorRate {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"status":"error","message":"inventory internal error"}`))
			return
		}

		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"success","items":["item-101","item-102","item-103"]}`))
	}))

	mux.HandleFunc("/chaos/configure", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			cfg := server.getChaosConfig()
			_ = json.NewEncoder(w).Encode(cfg)
			return
		}

		if r.Method == http.MethodPost {
			var cfg ChaosConfig
			if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"status":"error","message":"invalid json payload"}`))
				return
			}
			server.setChaosConfig(cfg)
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(server.getChaosConfig())
			return
		}

		w.WriteHeader(http.StatusMethodNotAllowed)
	})

	addr := fmt.Sprintf(":%s", port)
	log.Printf("Starting mock workload service on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Server terminated: %v", err)
	}
}
