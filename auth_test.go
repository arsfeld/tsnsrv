package tsnsrv

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestAuthMiddleware(t *testing.T) {
	// Test case 1: No auth URL configured - should pass through
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL: "",
		},
	}

	// Create a test handler that sets a header to verify it was called
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Test-Called", "true")
		w.WriteHeader(http.StatusOK)
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if w.Header().Get("Test-Called") != "true" {
		t.Error("Expected middleware to pass through when no auth URL configured")
	}
}

func TestAuthMiddlewareWithAuthService(t *testing.T) {
	// Create a mock auth service
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify the auth request has correct headers
		if r.Header.Get("X-Original-Method") != "GET" {
			t.Error("Expected X-Original-Method header")
		}
		if r.Header.Get("X-Forwarded-Proto") == "" {
			t.Error("Expected X-Forwarded-Proto header")
		}

		// Return 200 with a test header
		w.Header().Set("Remote-User", "testuser")
		w.WriteHeader(http.StatusOK)
	}))
	defer authServer.Close()

	// Configure auth middleware
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:     authServer.URL,
			AuthPath:    "/api/authz/forward-auth",
			AuthTimeout: 5 * time.Second,
			AuthCopyHeaders: headers{
				"Remote-User": []string{""},
			},
		},
	}

	// Create a test handler
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify the copied header is present
		if r.Header.Get("Remote-User") != "testuser" {
			t.Errorf("Expected Remote-User header to be 'testuser', got '%s'", r.Header.Get("Remote-User"))
		}
		w.WriteHeader(http.StatusOK)
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status OK, got %d", w.Code)
	}
}

func TestAuthMiddlewareUnauthorized(t *testing.T) {
	// Create a mock auth service that returns 401
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "/login")
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte("Unauthorized"))
	}))
	defer authServer.Close()

	// Configure auth middleware
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:     authServer.URL,
			AuthPath:    "/api/authz/forward-auth",
			AuthTimeout: 5 * time.Second,
		},
	}

	// Create a test handler (should not be called)
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Test handler should not be called when auth fails")
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("Expected status Unauthorized, got %d", w.Code)
	}
	if w.Header().Get("Location") != "/login" {
		t.Error("Expected Location header to be copied from auth response")
	}
}