package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
)

func main() {
	resp, err := http.Get("https://ident.me/json")
	if err != nil {
		log.Fatalf("Failed to get ident.me: %v", err)
	}
	var ident struct {
		IP      string `json:"ip"`
		Country string `json:"country"`
		ASO     string `json:"aso"`
		ASN     int    `json:"asn"`
	}
	err = json.NewDecoder(resp.Body).Decode(&ident)
	if err != nil {
		log.Fatalf("Failed to decode ident.me: %v", err)
	}
	if err := resp.Body.Close(); err != nil {
		log.Fatalf("Failed to close ident.me: %v", err)
	}

	http.ListenAndServe(":8080", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" && r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			return
		}

		id := "world"
		if len(r.URL.Path) > 1 {
			id = r.URL.Path[1:]
		}

		w.Write(fmt.Appendf(nil, "Hello, %s! Our IP is %s, which is registered to %s via AS%d in %s\n",
			id, ident.IP, ident.ASO, ident.ASN, ident.Country))
	}))
}
