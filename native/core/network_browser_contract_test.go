package core

import (
	"net/http"
	"testing"
)

func TestSubscriptionBrowserMediaHeadersRemainFetchStyle(t *testing.T) {
	credentials := &providerMediaCredentials{source: "sample", browser: true, referer: "https://source.example.test/video/1"}
	request, err := http.NewRequest(http.MethodGet, "https://media.example.test/video/1", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := credentials.apply(request); err != nil {
		t.Fatal(err)
	}
	if request.Header.Get("Sec-Fetch-Mode") != "cors" || request.Header.Get("Sec-Fetch-Dest") != "empty" || request.Header.Get("Origin") != "https://source.example.test" {
		t.Fatal("browser media request headers changed")
	}
}
