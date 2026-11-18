package core

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"net/url"
	"testing"
)

func TestDiagnosticNetworkCodeDoesNotExposeErrorText(t *testing.T) {
	for _, test := range []struct {
		err  error
		code string
	}{
		{context.Canceled, "canceled"},
		{context.DeadlineExceeded, "timeout"},
		{&net.DNSError{Err: "secret", Name: "private"}, "dns"},
		{&tls.CertificateVerificationError{Err: errors.New("secret")}, "tls_certificate"},
		{&net.OpError{Op: "dial", Err: errors.New("secret")}, "connection"},
		{errors.New("secret"), "request_failed"},
	} {
		err := &url.Error{Op: "Get", URL: "https://private.test/?token=secret", Err: test.err}
		if got := diagnosticNetworkCode(err); got != test.code {
			t.Errorf("got %q, want %q", got, test.code)
		}
	}
}
