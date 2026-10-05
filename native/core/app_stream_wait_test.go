package core

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestNativeMediaHeaderWaitIsBounded(t *testing.T) {
	stream := &nativeStreamServer{downloader: &Downloader{client: &http.Client{Transport: sourceFixtureTransport(func(r *http.Request) (*http.Response, error) {
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}}}
	request, _ := http.NewRequest(http.MethodGet, "https://synthetic.test/video.mp4", nil)
	start := time.Now()
	_, err := stream.nativeRequestWithIdleTimeout(request, 30*time.Millisecond)
	if err == nil || time.Since(start) > time.Second {
		t.Fatal("media header wait did not stop")
	}
}

func TestNativeMediaBodyStallIsBounded(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	stream := &nativeStreamServer{downloader: &Downloader{client: server.Client()}}
	request, _ := http.NewRequest(http.MethodGet, server.URL, nil)
	response, err := stream.nativeRequestWithIdleTimeout(request, 50*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	start := time.Now()
	_, err = io.ReadAll(response.Body)
	if err == nil || time.Since(start) > time.Second {
		t.Fatal("stalled body did not stop")
	}
}

func TestNativeMediaActiveStreamHasNoTotalDurationLimit(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for i := 0; i < 12; i++ {
			if _, err := w.Write([]byte{byte(i)}); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			time.Sleep(15 * time.Millisecond)
		}
	}))
	defer server.Close()
	stream := &nativeStreamServer{downloader: &Downloader{client: server.Client()}}
	request, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL, nil)
	response, err := stream.nativeRequestWithIdleTimeout(request, 80*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || len(body) != 12 {
		t.Fatalf("active stream was interrupted: bytes=%d error=%v", len(body), err)
	}
}
