// heimdall-verify is a tiny HTTP app that records its own ingress/egress at
// the application layer so you can compare against what heimdall's eBPF
// counters wrote into ClickHouse. Deploy it as a krane-shaped pod, drive
// traffic through it, then query `/stats` and run compare.sql.
//
// The eBPF side always reads higher because it sees TCP/IP/HTTP header
// overhead, probe traffic, TCP retransmits, and DNS. A healthy comparison:
// app_bytes < ch_bytes, ratio 0.85-0.99 depending on packet sizes.
package main

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

type entry struct {
	TSMillis  int64  `json:"ts_ms"`
	Direction string `json:"dir"` // "ingress" | "egress"
	Bytes     int64  `json:"bytes"`
	Path      string `json:"path"`
}

type podInfo struct {
	PodUID    string `json:"pod_uid"`
	PodName   string `json:"pod_name"`
	Namespace string `json:"namespace"`
	NodeName  string `json:"node_name"`
}

var (
	mu     sync.Mutex
	ledger []entry
	info   podInfo
)

func main() {
	info = podInfo{
		PodUID:    os.Getenv("POD_UID"),
		PodName:   os.Getenv("POD_NAME"),
		Namespace: os.Getenv("POD_NAMESPACE"),
		NodeName:  os.Getenv("NODE_NAME"),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/info", handleInfo)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/ingress", handleIngress)
	mux.HandleFunc("/egress", handleEgress)
	mux.HandleFunc("/echo", handleEcho)
	mux.HandleFunc("/ledger", handleLedger)
	mux.HandleFunc("/ledger.csv", handleLedgerCSV)
	mux.HandleFunc("/stats", handleStats)
	mux.HandleFunc("/reset", handleReset)

	addr := ":8080"
	if v := os.Getenv("PORT"); v != "" {
		addr = ":" + v
	}
	log.Printf("heimdall-verify listening on %s (pod_uid=%s pod=%s ns=%s node=%s)",
		addr, info.PodUID, info.PodName, info.Namespace, info.NodeName)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func record(dir string, n int64, path string) {
	mu.Lock()
	ledger = append(ledger, entry{
		TSMillis:  time.Now().UnixMilli(),
		Direction: dir,
		Bytes:     n,
		Path:      path,
	})
	mu.Unlock()
}

func handleInfo(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(info)
}

// POST /ingress with any body. Records the number of bytes received.
func handleIngress(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodPut {
		http.Error(w, "POST or PUT", http.StatusMethodNotAllowed)
		return
	}
	n, err := io.Copy(io.Discard, r.Body)
	_ = r.Body.Close()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	record("ingress", n, r.URL.Path)
	fmt.Fprintf(w, `{"ingress_bytes":%d}`+"\n", n)
}

// GET/POST /egress?bytes=N[&chunk=M]. Writes N bytes of junk back and
// records the number actually written (may be less if client disconnects).
func handleEgress(w http.ResponseWriter, r *http.Request) {
	want, err := strconv.ParseInt(r.URL.Query().Get("bytes"), 10, 64)
	if err != nil || want <= 0 {
		http.Error(w, "bytes query param required, must be > 0", http.StatusBadRequest)
		return
	}
	chunk := int64(64 * 1024)
	if c, err := strconv.ParseInt(r.URL.Query().Get("chunk"), 10, 64); err == nil && c > 0 {
		chunk = c
	}
	buf := bytes.Repeat([]byte{'x'}, int(chunk))
	w.Header().Set("Content-Length", strconv.FormatInt(want, 10))
	var written int64
	for written < want {
		n := chunk
		if want-written < n {
			n = want - written
		}
		m, err := w.Write(buf[:n])
		written += int64(m)
		if err != nil {
			break
		}
	}
	record("egress", written, r.URL.Path)
}

// POST /echo reads body (ingress) and writes it back (egress). Tests both
// directions in a single request — useful for roundtrip ratio checks.
func handleEcho(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodPut {
		http.Error(w, "POST or PUT", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	_ = r.Body.Close()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	record("ingress", int64(len(body)), r.URL.Path)
	n, err := w.Write(body)
	if err == nil {
		record("egress", int64(n), r.URL.Path)
	}
}

func snapshot() []entry {
	mu.Lock()
	defer mu.Unlock()
	out := make([]entry, len(ledger))
	copy(out, ledger)
	return out
}

// GET /ledger — newline-delimited JSON, one entry per line.
func handleLedger(w http.ResponseWriter, _ *http.Request) {
	snap := snapshot()
	w.Header().Set("Content-Type", "application/x-ndjson")
	enc := json.NewEncoder(w)
	for i := range snap {
		_ = enc.Encode(snap[i])
	}
}

// GET /ledger.csv — same content, CSV for `clickhouse-client --format=CSV`.
func handleLedgerCSV(w http.ResponseWriter, _ *http.Request) {
	snap := snapshot()
	w.Header().Set("Content-Type", "text/csv")
	cw := csv.NewWriter(w)
	_ = cw.Write([]string{"ts_ms", "dir", "bytes", "path"})
	for _, e := range snap {
		_ = cw.Write([]string{
			strconv.FormatInt(e.TSMillis, 10),
			e.Direction,
			strconv.FormatInt(e.Bytes, 10),
			e.Path,
		})
	}
	cw.Flush()
}

// GET /stats — rolled-up totals for quick eyeballing.
func handleStats(w http.ResponseWriter, _ *http.Request) {
	snap := snapshot()
	var in, eg int64
	var first, last int64
	for i, e := range snap {
		if e.Direction == "ingress" {
			in += e.Bytes
		} else {
			eg += e.Bytes
		}
		if i == 0 {
			first, last = e.TSMillis, e.TSMillis
			continue
		}
		if e.TSMillis < first {
			first = e.TSMillis
		}
		if e.TSMillis > last {
			last = e.TSMillis
		}
	}
	resp := map[string]any{
		"pod":           info,
		"entries":       len(snap),
		"ingress_bytes": in,
		"egress_bytes":  eg,
		"total_bytes":   in + eg,
		"first_ts_ms":   first,
		"last_ts_ms":    last,
		"duration_ms":   last - first,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// POST /reset — clears the ledger. Useful before starting a new test run.
func handleReset(w http.ResponseWriter, _ *http.Request) {
	mu.Lock()
	ledger = nil
	mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}
