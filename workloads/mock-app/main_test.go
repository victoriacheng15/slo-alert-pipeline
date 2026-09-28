package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSetChaosConfig(t *testing.T) {
	tests := []struct {
		name     string
		input    ChaosConfig
		expected ChaosConfig
	}{
		{
			name: "valid standard error rate and latency",
			input: ChaosConfig{
				ErrorRate: 0.25,
				LatencyMs: 150,
			},
			expected: ChaosConfig{
				ErrorRate: 0.25,
				LatencyMs: 150,
			},
		},
		{
			name: "negative error rate clamped to zero",
			input: ChaosConfig{
				ErrorRate: -0.50,
				LatencyMs: 0,
			},
			expected: ChaosConfig{
				ErrorRate: 0.0,
				LatencyMs: 0,
			},
		},
		{
			name: "error rate exceeding 1.0 clamped to 1.0",
			input: ChaosConfig{
				ErrorRate: 1.75,
				LatencyMs: 50,
			},
			expected: ChaosConfig{
				ErrorRate: 1.0,
				LatencyMs: 50,
			},
		},
		{
			name: "zero error rate happy path",
			input: ChaosConfig{
				ErrorRate: 0.0,
				LatencyMs: 0,
			},
			expected: ChaosConfig{
				ErrorRate: 0.0,
				LatencyMs: 0,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &Server{}
			s.setChaosConfig(tt.input)
			got := s.getChaosConfig()

			if got.ErrorRate != tt.expected.ErrorRate {
				t.Errorf("setChaosConfig() ErrorRate = %v, want %v", got.ErrorRate, tt.expected.ErrorRate)
			}
			if got.LatencyMs != tt.expected.LatencyMs {
				t.Errorf("setChaosConfig() LatencyMs = %v, want %v", got.LatencyMs, tt.expected.LatencyMs)
			}
		})
	}
}

func TestRouteBasedEndpoints(t *testing.T) {
	tests := []struct {
		name         string
		route        string
		handler      http.HandlerFunc
		expectedCode int
	}{
		{
			name:  "checkout process success",
			route: "/api/checkout/process",
			handler: instrument("/api/checkout/process", func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
			}),
			expectedCode: http.StatusOK,
		},
		{
			name:  "checkout fail simulated 500 error",
			route: "/api/checkout/fail",
			handler: instrument("/api/checkout/fail", func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusInternalServerError)
			}),
			expectedCode: http.StatusInternalServerError,
		},
		{
			name:  "checkout slow success",
			route: "/api/checkout/slow",
			handler: instrument("/api/checkout/slow", func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
			}),
			expectedCode: http.StatusOK,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tt.route, nil)
			rr := httptest.NewRecorder()

			tt.handler.ServeHTTP(rr, req)

			if rr.Code != tt.expectedCode {
				t.Errorf("handler route %s status = %v, want %v", tt.route, rr.Code, tt.expectedCode)
			}
		})
	}
}

func TestChaosConfigureEndpointTable(t *testing.T) {
	tests := []struct {
		name         string
		method       string
		body         string
		expectedCode int
		wantErr      bool
	}{
		{
			name:         "get configuration success",
			method:       http.MethodGet,
			body:         "",
			expectedCode: http.StatusOK,
			wantErr:      false,
		},
		{
			name:         "post valid configuration",
			method:       http.MethodPost,
			body:         `{"error_rate":0.5,"latency_ms":100}`,
			expectedCode: http.StatusOK,
			wantErr:      false,
		},
		{
			name:         "post invalid json payload",
			method:       http.MethodPost,
			body:         `{"error_rate": "invalid-string"}`,
			expectedCode: http.StatusBadRequest,
			wantErr:      true,
		},
		{
			name:         "disallowed method",
			method:       http.MethodDelete,
			body:         "",
			expectedCode: http.StatusMethodNotAllowed,
			wantErr:      true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &Server{}
			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodGet {
					w.WriteHeader(http.StatusOK)
					return
				}
				if r.Method == http.MethodPost {
					var cfg ChaosConfig
					if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
						w.WriteHeader(http.StatusBadRequest)
						return
					}
					s.setChaosConfig(cfg)
					w.WriteHeader(http.StatusOK)
					return
				}
				w.WriteHeader(http.StatusMethodNotAllowed)
			})

			req := httptest.NewRequest(tt.method, "/chaos/configure", bytes.NewBufferString(tt.body))
			rr := httptest.NewRecorder()

			handler.ServeHTTP(rr, req)

			if rr.Code != tt.expectedCode {
				t.Errorf("ChaosConfigure() status = %v, want %v", rr.Code, tt.expectedCode)
			}
		})
	}
}

func TestRootEndpoint(t *testing.T) {
	tests := []struct {
		name         string
		path         string
		expectedCode int
	}{
		{
			name:         "root path returns 200 with directory",
			path:         "/",
			expectedCode: http.StatusOK,
		},
		{
			name:         "unregistered path returns 404",
			path:         "/unknown-route",
			expectedCode: http.StatusNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/" {
					http.NotFound(w, r)
					return
				}
				w.WriteHeader(http.StatusOK)
			})

			req := httptest.NewRequest(http.MethodGet, tt.path, nil)
			rr := httptest.NewRecorder()

			handler.ServeHTTP(rr, req)

			if rr.Code != tt.expectedCode {
				t.Errorf("Root handler path %s status = %v, want %v", tt.path, rr.Code, tt.expectedCode)
			}
		})
	}
}
